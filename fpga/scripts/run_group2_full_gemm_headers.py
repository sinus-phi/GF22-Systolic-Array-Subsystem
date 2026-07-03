#!/usr/bin/env python3
"""Run one full 32x32x32 GROUP2 GEMM ELF for each school-provided header.

This is the preferred v2 FPGA validation mode now that the RISC-V data memory
is large enough for one complete GEMM header at a time.  The runner generates
one RISC-V C program per header, links one ELF per header, and optionally loads
each ELF over FT232H JTAG while the Nucleo UART bridge captures the result.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


BITS_TO_PRECISION = {
    4: "GROUP2_SA_DTYPE_INT4",
    8: "GROUP2_SA_DTYPE_INT8",
    16: "GROUP2_SA_DTYPE_INT16",
    32: "GROUP2_SA_DTYPE_INT32",
}

EXPECTED_INVALID_HEADERS = {
    "array_mode6_8b_4b_32_32_32_row-index.h",
}


C_TEMPLATE = r'''#include <stdint.h>
#include "group2_sa.h"
#include "group2_uart_print.h"
#include "@HEADER_NAME@"

#define TILE_M 8u
#define TILE_N 8u
#define TILE_K 8u
#define ACT_PRECISION @ACT_PRECISION@
#define WEIGHT_PRECISION @WEIGHT_PRECISION@
#define EXPECTED_INVALID @EXPECTED_INVALID@u
#define HEADER_TOKEN "@HEADER_TOKEN@"

static int64_t accum[M_d * N_d];

static void short_delay(void)
{
  for (volatile uint32_t i = 0; i < 1000u; ++i) {
    asm volatile("nop");
  }
}

static void print_i64_hex(int64_t value)
{
  uint64_t bits = (uint64_t)value;
  group2_print_hex32((uint32_t)(bits >> 32));
  group2_print_char('_');
  group2_print_hex32((uint32_t)bits);
}

static void clear_accum(void)
{
  for (uint32_t i = 0u; i < (uint32_t)(M_d * N_d); ++i) {
    accum[i] = 0;
  }
}

static int wait_or_report(uint32_t expected_phase, uint32_t timeout, const char *tag)
{
  uint32_t status = 0u;
  if (group2_sa_wait_phase(expected_phase, timeout, &status) == 0) {
    return 0;
  }

  group2_print_str("FULL_GEMM_ERROR,");
  group2_print_str(HEADER_TOKEN);
  group2_print_str(",");
  group2_print_str(tag);
  group2_print_str(",status=");
  group2_print_hex32(status);
  group2_print_str("\r\n");
  return 1;
}

static int wait_output_or_report(const char *tag)
{
  uint32_t status = 0u;
  if (group2_sa_wait_output_valid(60000u, &status) != 0) {
    group2_print_str("FULL_GEMM_ERROR,");
    group2_print_str(HEADER_TOKEN);
    group2_print_str(",");
    group2_print_str(tag);
    group2_print_str(",status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    return 1;
  }

  if (group2_sa_status_output_words(status) != (TILE_M * TILE_N * 2u)) {
    group2_print_str("FULL_GEMM_ERROR,");
    group2_print_str(HEADER_TOKEN);
    group2_print_str(",bad_output_words,status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    return 1;
  }

  return 0;
}

static int run_tile(uint32_t n_base, uint32_t k_base)
{
  int errors = 0;
  int32_t vec[TILE_K];

  uint32_t cfg = group2_sa_make_config(ACT_PRECISION, WEIGHT_PRECISION,
                                       TILE_M, TILE_N, TILE_K, M_d / TILE_M);
  group2_sa_write32(GROUP2_SA_OFF_CONFIG, cfg);
  group2_sa_write32(GROUP2_SA_OFF_CONTROL, GROUP2_SA_CTRL_LOAD_WEIGHTS);

  if (wait_or_report(GROUP2_SA_PH_LOAD_WEIGHTS, 12000u, "load_weight_phase") != 0) {
    return 1;
  }

  for (uint32_t n = 0u; n < TILE_N; ++n) {
    for (uint32_t k = 0u; k < TILE_K; ++k) {
      vec[k] = (int32_t)weights_unpacked[(n_base + n) * K_d + (k_base + k)];
    }
    group2_sa_stream_weight_vector(vec, WEIGHT_PRECISION, TILE_K);
  }

  if (wait_or_report(GROUP2_SA_PH_BATCH_COMPUTE, 16000u, "batch_compute_phase") != 0) {
    return 1;
  }

  for (uint32_t m_base = 0u; m_base < M_d; m_base += TILE_M) {
    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t k = 0u; k < TILE_K; ++k) {
        vec[k] = (int32_t)input_unpacked[(m_base + m) * K_d + (k_base + k)];
      }
      group2_sa_stream_activation_vector(vec, ACT_PRECISION, TILE_K);
    }

    if (wait_output_or_report("output_valid") != 0) {
      return 1;
    }

    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t n = 0u; n < TILE_N; ++n) {
        uint32_t dst = (m_base + m) * N_d + (n_base + n);
        accum[dst] += group2_sa_read_output_elem(m, n, TILE_N);
      }
    }

    group2_sa_release_output();
    if ((m_base + TILE_M) < M_d) {
      errors += wait_or_report(GROUP2_SA_PH_BATCH_COMPUTE, 16000u, "next_batch_phase");
    } else {
      errors += wait_or_report(GROUP2_SA_PH_IDLE, 16000u, "idle_phase");
    }

    if (errors != 0) {
      return errors;
    }
  }

  return errors;
}

static int run_all_tiles(void)
{
  int errors = 0;

  for (uint32_t n_base = 0u; n_base < N_d; n_base += TILE_N) {
    for (uint32_t k_base = 0u; k_base < K_d; k_base += TILE_K) {
      errors += run_tile(n_base, k_base);
      if (errors != 0) {
        group2_sa_soft_reset();
        return errors;
      }
    }
  }

  return errors;
}

static int compare_result(void)
{
  int errors = 0;

  for (uint32_t m = 0u; m < M_d; ++m) {
    for (uint32_t n = 0u; n < N_d; ++n) {
      uint32_t idx = m * N_d + n;
      C_TYPE actual = (C_TYPE)(accum[idx] + (int64_t)bias[n]);
      C_TYPE expected = golden[idx];

      if (actual != expected) {
        if (errors < 8) {
          group2_print_str("FULL_GEMM_MISMATCH,");
          group2_print_str(HEADER_TOKEN);
          group2_print_str(",m=");
          group2_print_i32((int32_t)m);
          group2_print_str(",n=");
          group2_print_i32((int32_t)n);
          group2_print_str(",golden=");
          print_i64_hex((int64_t)expected);
          group2_print_str(",actual=");
          print_i64_hex((int64_t)actual);
          group2_print_str("\r\n");
        }
        errors++;
      }
    }
  }

  return errors;
}

static void print_done(int runtime_errors, int mismatches)
{
  int pass = (runtime_errors == 0) && ((mismatches == 0) || (EXPECTED_INVALID != 0u));

  group2_print_str("FULL_GEMM_DONE,");
  group2_print_str(HEADER_TOKEN);
  group2_print_str(",runtime_errors=");
  group2_print_i32(runtime_errors);
  group2_print_str(",mismatches=");
  group2_print_i32(mismatches);
  group2_print_str(",expected_invalid=");
  group2_print_i32((int32_t)EXPECTED_INVALID);
  group2_print_str(",");
  group2_print_str(pass ? "PASS" : "FAIL");
  group2_print_str("\r\n");
}

int main(void)
{
  int runtime_errors = 0;
  int mismatches = 0;

  group2_print_init();
  group2_print_str("\r\nFULL_GEMM_START,");
  group2_print_str(HEADER_TOKEN);
  group2_print_str("\r\n");

  if (((M_d % TILE_M) != 0) || ((N_d % TILE_N) != 0) || ((K_d % TILE_K) != 0)) {
    group2_print_str("FULL_GEMM_ERROR,");
    group2_print_str(HEADER_TOKEN);
    group2_print_str(",bad_dimensions\r\n");
    print_done(1, 0);
    while (1) {}
  }

  clear_accum();
  group2_sa_disable();
  short_delay();
  group2_sa_enable();
  short_delay();
  group2_sa_soft_reset();

  runtime_errors = run_all_tiles();
  if (runtime_errors == 0) {
    mismatches = compare_result();
  }

  print_done(runtime_errors, mismatches);
  while (1) {}
}
'''


def strip_c_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def parse_c_array(header: Path, name: str) -> list[int]:
    text = strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"\b{name}\s*\[[^\]]*\]\s*=\s*\{{(.*?)\}};", text, flags=re.S)
    if not match:
        raise ValueError(f"array {name!r} not found in {header}")
    return [int(token, 0) for token in re.findall(r"[-+]?(?:0x[0-9a-fA-F]+|\d+)", match.group(1))]


def parse_define_int(header: Path, name: str) -> int:
    text = strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"^\s*#define\s+{name}\s+(\d+)\s*$", text, flags=re.M)
    if not match:
        raise ValueError(f"#define {name} not found in {header}")
    return int(match.group(1), 10)


def parse_type_width(header: Path, macro: str) -> int:
    text = strip_c_comments(header.read_text(encoding="utf-8"))
    match = re.search(rf"^\s*#define\s+{macro}\s+int(\d+)_t\s*$", text, flags=re.M)
    if not match:
        raise ValueError(f"#define {macro} int*_t not found in {header}")
    return int(match.group(1), 10)


def parse_precision_bits(header: Path) -> tuple[int, int]:
    match = re.search(r"array_mode\d+_(\d+)b_(\d+)b_", header.name)
    if not match:
        raise ValueError(f"cannot infer precision from header name: {header.name}")
    return int(match.group(1)), int(match.group(2))


def signed_range(width: int) -> tuple[int, int]:
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def sign_extend(value: int, width: int) -> int:
    value &= (1 << width) - 1
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def cast_signed(value: int, width: int) -> int:
    if width >= 64:
        return value
    return sign_extend(value, width)


def header_range_is_valid(values: list[int], width: int) -> bool:
    lo, hi = signed_range(width)
    return min(values) >= lo and max(values) <= hi


def sanitize_token(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]+", "_", name).strip("_")


def c_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def make_linker_script() -> str:
    return r"""OUTPUT_ARCH(riscv)
SEARCH_DIR(.)
__DYNAMIC = 0;

MEMORY
{
  IMEM (rx ) : ORIGIN = 0x01000000, LENGTH = 0x4000
  DMEM (rwx) : ORIGIN = 0x01100000, LENGTH = 0x20000
}

STACK_SIZE = 0xC00;

SECTIONS
{
  .text : ALIGN(4)
  {
    KEEP(*(.vectors .vectors.*))
    _stext = .;
    *(.text*)
    _etext = .;
    *(.rodata*)
  } > IMEM

  .data : ALIGN(4)
  {
    *(.data*);
  } > DMEM

  .sdata : ALIGN(4)
  {
    *(.sdata*);
  } > DMEM

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss*)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DMEM

  .stack (NOLOAD) :
  {
    . = ALIGN(4);
    stack = . + STACK_SIZE;
  } > DMEM

  _end = . ;
}
"""


def make_full_source(header: Path, token: str, act_bits: int, weight_bits: int, expected_invalid: bool) -> str:
    source = C_TEMPLATE
    replacements = {
        "@HEADER_NAME@": c_quote(header.name),
        "@HEADER_TOKEN@": c_quote(token),
        "@ACT_PRECISION@": BITS_TO_PRECISION[act_bits],
        "@WEIGHT_PRECISION@": BITS_TO_PRECISION[weight_bits],
        "@EXPECTED_INVALID@": "1" if expected_invalid else "0",
    }
    for key, value in replacements.items():
        source = source.replace(key, value)
    return source


def run_command(
    args: list[str],
    *,
    cwd: Path | None = None,
    log_path: Path | None = None,
    check: bool = True,
    stdout=None,
    stderr=None,
) -> subprocess.CompletedProcess:
    if log_path is not None:
        with log_path.open("w", encoding="utf-8") as log:
            proc = subprocess.run(args, cwd=cwd, text=True, stdout=log, stderr=subprocess.STDOUT)
    else:
        proc = subprocess.run(args, cwd=cwd, text=True, stdout=stdout, stderr=stderr)

    if check and proc.returncode != 0:
        rendered = " ".join(args)
        raise RuntimeError(f"command failed ({proc.returncode}): {rendered}")
    return proc


def compile_full_header(
    *,
    repo: Path,
    work_dir: Path,
    source_path: Path,
    elf_path: Path,
    arch: str,
    cc: str,
) -> None:
    sw_dir = repo / "fpga" / "sw"
    common_dir = sw_dir / "common"
    include_dir = sw_dir / "gemm" / "include"
    obj_path = source_path.with_suffix(".o")
    crt_obj = work_dir / "crt0.o"
    link_script = work_dir / "link_full_gemm.ld"

    if not link_script.exists():
        link_script.write_text(make_linker_script(), encoding="utf-8")

    cflags = [
        "-march=" + arch,
        "-D__riscv__",
        "-mabi=ilp32",
        "-Os",
        "-w",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-tree-loop-distribute-patterns",
        "-ffunction-sections",
        "-fdata-sections",
        "-I" + str(common_dir),
        "-I" + str(include_dir),
    ]

    run_command([cc, *cflags, "-c", str(source_path), "-o", str(obj_path)])
    if not crt_obj.exists():
        run_command([
            cc,
            "-march=" + arch,
            "-D__riscv__",
            "-mabi=ilp32",
            "-DLANGUAGE_ASSEBMLY",
            "-c",
            str(common_dir / "crt0.S"),
            "-o",
            str(crt_obj),
        ])
    run_command([
        cc,
        "-march=" + arch,
        "-T" + str(link_script),
        str(obj_path),
        str(crt_obj),
        "-nostartfiles",
        "-nostdlib",
        "-Wl,--gc-sections",
        "-Wl,--build-id=none",
        "-o",
        str(elf_path),
    ])


def reset_nucleo(log_path: Path) -> None:
    run_command([
        "openocd",
        "-f",
        "interface/stlink.cfg",
        "-f",
        "target/stm32f4x.cfg",
        "-c",
        "init",
        "-c",
        "reset run",
        "-c",
        "shutdown",
    ], log_path=log_path)
    time.sleep(0.4)


def halt_riscv(openocd_cfg: Path) -> None:
    run_command([
        "openocd",
        "-f",
        str(openocd_cfg),
        "-c",
        "halt",
        "-c",
        "shutdown",
    ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def load_and_run_elf(openocd_cfg: Path, elf_path: Path, wait_ms: int, log_path: Path) -> None:
    run_command([
        "openocd",
        "-f",
        str(openocd_cfg),
        "-c",
        "halt",
        "-c",
        f"load_image {elf_path}",
        "-c",
        "resume 0x01000080",
        "-c",
        f"sleep {wait_ms}",
        "-c",
        "shutdown",
    ], cwd=openocd_cfg.parents[1], log_path=log_path)


def run_full_elf(
    *,
    repo: Path,
    uart_capture: Path,
    uart_dev: str,
    uart_baud: int,
    header_timeout: int,
    openocd_cfg: Path,
    elf_path: Path,
    wait_ms: int,
    log_prefix: Path,
) -> None:
    uart_log = log_prefix.with_suffix(".uart.log")
    openocd_log = log_prefix.with_suffix(".openocd.log")
    nucleo_log = log_prefix.with_suffix(".nucleo_reset.log")

    halt_riscv(openocd_cfg)
    capture = subprocess.Popen([
        sys.executable,
        str(uart_capture),
        "--dev",
        uart_dev,
        "--baud",
        str(uart_baud),
        "--timeout",
        str(header_timeout),
        "--log",
        str(uart_log),
        "--pass-regex",
        r"FULL_GEMM_DONE,.*PASS",
        "--fail-regex",
        r"FULL_GEMM_DONE,.*FAIL|FULL_GEMM_ERROR",
    ], cwd=repo)

    try:
        time.sleep(0.25)
        reset_nucleo(nucleo_log)
        time.sleep(0.25)
        load_and_run_elf(openocd_cfg, elf_path, wait_ms, openocd_log)
        rc = capture.wait()
    except Exception:
        capture.kill()
        capture.wait()
        raise

    if rc != 0:
        raise RuntimeError(f"UART full-GEMM run failed rc={rc}; see {uart_log}")


def compute_header_mismatches(
    *,
    full_m: int,
    full_n: int,
    full_k: int,
    act_bits: int,
    weight_bits: int,
    c_width: int,
    a_full: list[int],
    w_full: list[int],
    bias: list[int],
    golden: list[int],
) -> tuple[int, list[tuple[int, int, int, int]]]:
    mismatches = 0
    samples: list[tuple[int, int, int, int]] = []
    for m in range(full_m):
        for n in range(full_n):
            acc = 0
            for k in range(full_k):
                a = cast_signed(a_full[m * full_k + k], act_bits)
                w = cast_signed(w_full[n * full_k + k], weight_bits)
                acc += a * w
            actual = cast_signed(acc + bias[n], c_width)
            expected = cast_signed(golden[m * full_n + n], c_width)
            if actual != expected:
                mismatches += 1
                if len(samples) < 8:
                    samples.append((m, n, expected, actual))
    return mismatches, samples


def run_header(
    *,
    args: argparse.Namespace,
    header: Path,
    header_idx: int,
    total_headers: int,
    work_dir: Path,
) -> tuple[int, int, bool]:
    act_bits, weight_bits = parse_precision_bits(header)
    full_m = parse_define_int(header, "M_d")
    full_k = parse_define_int(header, "K_d")
    full_n = parse_define_int(header, "N_d")
    c_width = parse_type_width(header, "C_TYPE")
    a_full = parse_c_array(header, "input_unpacked")
    w_full = parse_c_array(header, "weights_unpacked")
    bias = parse_c_array(header, "bias")
    golden = parse_c_array(header, "golden")

    if full_m % 8 or full_k % 8 or full_n % 8:
        raise ValueError(f"{header.name}: dimensions must be multiples of 8")
    if act_bits not in BITS_TO_PRECISION or weight_bits not in BITS_TO_PRECISION:
        raise ValueError(f"{header.name}: unsupported precision A={act_bits}, W={weight_bits}")

    act_range_ok = header_range_is_valid(a_full, act_bits)
    weight_range_ok = header_range_is_valid(w_full, weight_bits)
    expected_invalid = (not act_range_ok) or (not weight_range_ok) or (header.name in EXPECTED_INVALID_HEADERS)
    if args.include_invalid:
        expected_invalid = False

    token = sanitize_token(header.stem)
    header_dir = work_dir / f"{header_idx:02d}_{token}"
    header_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"FULL_HEADER_BEGIN,{header_idx}/{total_headers},{header.name},"
        f"M={full_m},K={full_k},N={full_n},A={act_bits},W={weight_bits},"
        f"C={c_width},expected_invalid={int(expected_invalid)}",
        flush=True,
    )

    source_path = header_dir / f"{token}.c"
    elf_path = header_dir / f"{token}.elf"
    source_path.write_text(
        make_full_source(header, token, act_bits, weight_bits, expected_invalid),
        encoding="utf-8",
    )

    compile_full_header(
        repo=args.repo,
        work_dir=header_dir,
        source_path=source_path,
        elf_path=elf_path,
        arch=args.riscv_arch,
        cc=args.cc,
    )

    if not args.compile_only:
        run_full_elf(
            repo=args.repo,
            uart_capture=args.uart_capture,
            uart_dev=args.uart_dev,
            uart_baud=args.uart_baud,
            header_timeout=args.header_timeout,
            openocd_cfg=args.openocd_cfg,
            elf_path=elf_path,
            wait_ms=args.elf_wait_ms,
            log_prefix=header_dir / token,
        )

    mismatches, samples = compute_header_mismatches(
        full_m=full_m,
        full_n=full_n,
        full_k=full_k,
        act_bits=act_bits,
        weight_bits=weight_bits,
        c_width=c_width,
        a_full=a_full,
        w_full=w_full,
        bias=bias,
        golden=golden,
    )

    fatal_mismatches = 0 if (expected_invalid and mismatches) else mismatches
    for m, n, expected, actual in samples:
        print(
            f"FULL_HEADER_MISMATCH_SAMPLE,{header.name},m={m},n={n},"
            f"golden={expected},actual={actual}",
            flush=True,
        )

    if mismatches and expected_invalid:
        result = "EXPECTED_INVALID"
    else:
        result = "PASS" if mismatches == 0 else "FAIL"

    size_line = ""
    size_tool = shutil.which(args.size)
    if size_tool is not None:
        proc = run_command([size_tool, str(elf_path)], check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode == 0 and proc.stdout:
            parts = proc.stdout.strip().splitlines()
            if len(parts) >= 2:
                cols = parts[1].split()
                if len(cols) >= 4:
                    size_line = f",text={cols[0]},data={cols[1]},bss={cols[2]},dec={cols[3]}"

    print(
        f"FULL_HEADER_DONE,{header.name},elf={elf_path},"
        f"matched={full_m * full_n - mismatches},mismatches={mismatches},"
        f"result={result}{size_line}",
        flush=True,
    )
    return full_m * full_n, fatal_mismatches, expected_invalid and mismatches != 0


def parse_args() -> argparse.Namespace:
    repo_default = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument("--headers-glob", default="array_mode*.h")
    parser.add_argument("--include-invalid", action="store_true",
                        help="Treat precision-range-invalid headers as fatal failures")
    parser.add_argument("--limit-headers", type=int, default=0,
                        help="Debug aid: run only the first N matched headers")
    parser.add_argument("--compile-only", action="store_true",
                        help="Generate and link one full GEMM ELF per header, but do not touch hardware")
    parser.add_argument("--log-dir", type=Path,
                        default=repo_default / "build" / "fpga" / "group2_full_gemm_headers")
    parser.add_argument("--uart-dev", default="/dev/ttyACM0")
    parser.add_argument("--uart-baud", type=int, default=9600)
    parser.add_argument("--header-timeout", type=int, default=90)
    parser.add_argument("--elf-wait-ms", type=int, default=12000)
    parser.add_argument("--openocd-cfg", type=Path,
                        default=repo_default / "fpga" / "utils" / "openocd-didactic-ft232h-z2.cfg")
    parser.add_argument("--uart-capture", type=Path,
                        default=repo_default / "fpga" / "scripts" / "uart_capture_until.py")
    parser.add_argument("--cc", default="riscv64-unknown-elf-gcc")
    parser.add_argument("--size", default="riscv64-unknown-elf-size")
    parser.add_argument("--riscv-arch", default=os.getenv("RISCV_ARCH", "rv32imc_zicsr"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.repo = args.repo.resolve()
    args.log_dir = args.log_dir.resolve()
    args.openocd_cfg = args.openocd_cfg.resolve()
    args.uart_capture = args.uart_capture.resolve()

    if shutil.which(args.cc) is None:
        print(f"ERROR: compiler not found: {args.cc}", file=sys.stderr)
        return 2
    if not args.compile_only:
        if shutil.which("openocd") is None:
            print("ERROR: openocd not found", file=sys.stderr)
            return 2
        if not args.openocd_cfg.exists():
            print(f"ERROR: OpenOCD config not found: {args.openocd_cfg}", file=sys.stderr)
            return 2
        if not args.uart_capture.exists():
            print(f"ERROR: UART capture helper not found: {args.uart_capture}", file=sys.stderr)
            return 2

    include_dir = args.repo / "fpga" / "sw" / "gemm" / "include"
    headers = sorted(include_dir.glob(args.headers_glob))
    if args.limit_headers:
        headers = headers[: args.limit_headers]
    if not headers:
        print(f"ERROR: no headers matched {args.headers_glob!r} under {include_dir}", file=sys.stderr)
        return 2

    args.log_dir.mkdir(parents=True, exist_ok=True)
    work_dir = args.log_dir / "generated_full_headers"
    work_dir.mkdir(parents=True, exist_ok=True)

    print("GROUP2 full GEMM one-ELF-per-header run", flush=True)
    print(f"headers={len(headers)} glob={args.headers_glob}", flush=True)
    print(f"log_dir={args.log_dir}", flush=True)

    total_values = 0
    total_fatal_mismatches = 0
    expected_invalid_count = 0
    failed_headers: list[str] = []
    expected_invalid_headers: list[str] = []

    for idx, header in enumerate(headers, start=1):
        try:
            header_total, fatal_mismatches, expected_invalid = run_header(
                args=args,
                header=header,
                header_idx=idx,
                total_headers=len(headers),
                work_dir=work_dir,
            )
        except Exception as exc:
            print(
                f"FULL_HEADER_DONE,{header.name},elf=unknown,matched=0,"
                "mismatches=unknown,result=FAIL",
                flush=True,
            )
            print(f"ERROR: {header.name}: {exc}", file=sys.stderr, flush=True)
            failed_headers.append(header.name)
            total_fatal_mismatches += 1
            continue

        total_values += header_total
        total_fatal_mismatches += fatal_mismatches
        if expected_invalid:
            expected_invalid_count += 1
            expected_invalid_headers.append(header.name)
        if fatal_mismatches:
            failed_headers.append(header.name)

    passed = total_fatal_mismatches == 0
    print(
        "ALL_FULL_GEMM_FINAL,"
        f"headers={len(headers)},total={total_values},"
        f"fatal_mismatches={total_fatal_mismatches},"
        f"expected_invalid={expected_invalid_count},"
        f"failed_headers={';'.join(failed_headers) if failed_headers else 'none'},"
        f"expected_invalid_headers={';'.join(expected_invalid_headers) if expected_invalid_headers else 'none'},"
        f"{'PASS' if passed else 'FAIL'}",
        flush=True,
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
