#!/usr/bin/env python3
"""Run each sw/gemm header on SS2 hardware one tile ELF at a time.

The RISC-V memories in this Didactic SoC image are intentionally small
(4 KiB IMEM and 4 KiB DMEM).  A full 32x32x32 GEMM header does not fit as one
bare-metal program.  This runner keeps the same hardware path, but splits each
header into 8x8x8 tiles.  For every header/N-tile/K-tile it generates a tiny
ELF, loads it over FT232H JTAG, and lets the RISC-V CPU drive SS2 through the
HAL.
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
    4: "SS2_SA_DTYPE_INT4",
    8: "SS2_SA_DTYPE_INT8",
    16: "SS2_SA_DTYPE_INT16",
    32: "SS2_SA_DTYPE_INT32",
}

EXPECTED_INVALID_HEADERS = {
    "array_mode6_8b_4b_32_32_32_row-index.h",
}


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


def sign_extend(value: int, width: int) -> int:
    value &= (1 << width) - 1
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def cast_signed(value: int, width: int) -> int:
    if width >= 64:
        return value
    return sign_extend(value, width)


def signed_range(width: int) -> tuple[int, int]:
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def sanitize_token(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]+", "_", name).strip("_")


def c_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def c_int32(value: int) -> str:
    return f"INT32_C({value})"


def format_c_matrix(rows: list[list[int]], indent: str = "  ") -> str:
    lines = []
    for row in rows:
        values = ", ".join(c_int32(value) for value in row)
        lines.append(f"{indent}{{ {values} }}")
    return ",\n".join(lines)


def make_linker_script() -> str:
    return r"""OUTPUT_ARCH(riscv)
SEARCH_DIR(.)
__DYNAMIC = 0;

MEMORY
{
  IMEM (rx ) : ORIGIN = 0x01000000, LENGTH = 0x1000
  DMEM (rwx) : ORIGIN = 0x01010000, LENGTH = 0x1000
}

STACK_SIZE = 0x400;

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
    *(.bss*)
    *(COMMON)
  } > DMEM

  .stack (NOLOAD) :
  {
    . = ALIGN(4);
    stack = . + STACK_SIZE;
  } > DMEM

  _end = . ;
}
"""


def make_tile_source(
    *,
    header_token: str,
    n_base: int,
    k_base: int,
    act_bits: int,
    weight_bits: int,
    weights: list[list[int]],
    act_batches: list[list[list[int]]],
) -> str:
    weight_rows = format_c_matrix(weights, "  ")
    batch_blocks = []
    for batch in act_batches:
        batch_blocks.append("  {\n" + format_c_matrix(batch, "    ") + "\n  }")
    act_blocks = ",\n".join(batch_blocks)

    return f"""#include <stdint.h>
#include "ss2_sa.h"
#include "ss2_uart_print.h"

#define TILE_M 8u
#define TILE_N 8u
#define TILE_K 8u
#define BATCH_COUNT 4u
#define ACT_BITS {act_bits}u
#define WEIGHT_BITS {weight_bits}u
#define ACT_PRECISION {BITS_TO_PRECISION[act_bits]}
#define WEIGHT_PRECISION {BITS_TO_PRECISION[weight_bits]}
#define HEADER_TOKEN {c_string(header_token)}
#define N_BASE {n_base}u
#define K_BASE {k_base}u

static int32_t weights[TILE_N][TILE_K] = {{
{weight_rows}
}};

static int32_t acts[BATCH_COUNT][TILE_M][TILE_K] = {{
{act_blocks}
}};

static void short_delay(void)
{{
  for (volatile uint32_t i = 0; i < 1000u; ++i) {{
    asm volatile("nop");
  }}
}}

static int32_t cast_width(int32_t value, uint32_t width)
{{
  if (width >= 32u) {{
    return value;
  }}

  uint32_t mask = (1u << width) - 1u;
  uint32_t bits = ((uint32_t)value) & mask;
  uint32_t sign = 1u << (width - 1u);
  if ((bits & sign) != 0u) {{
    bits |= ~mask;
  }}
  return (int32_t)bits;
}}

static int64_t expected_elem(uint32_t batch, uint32_t row, uint32_t col)
{{
  int64_t acc = 0;
  for (uint32_t k = 0u; k < TILE_K; ++k) {{
    int32_t a = cast_width(acts[batch][row][k], ACT_BITS);
    int32_t w = cast_width(weights[col][k], WEIGHT_BITS);
    acc += (int64_t)a * (int64_t)w;
  }}
  return acc;
}}

static void print_i64_hex(int64_t value)
{{
  uint64_t bits = (uint64_t)value;
  ss2_print_hex32((uint32_t)(bits >> 32));
  ss2_print_char('_');
  ss2_print_hex32((uint32_t)bits);
}}

static void print_tile_done(int errors)
{{
  ss2_print_str("HEADER_TILE_DONE,");
  ss2_print_str(HEADER_TOKEN);
  ss2_print_str(",n=");
  ss2_print_i32((int32_t)N_BASE);
  ss2_print_str(",k=");
  ss2_print_i32((int32_t)K_BASE);
  ss2_print_str(",");
  ss2_print_str(errors == 0 ? "PASS" : "FAIL");
  ss2_print_str(",errors=");
  ss2_print_i32(errors);
  ss2_print_str("\\r\\n");
}}

int main(void)
{{
  int errors = 0;
  uint32_t status = 0u;

  ss2_print_init();
  ss2_print_str("\\r\\nHEADER_TILE_START,");
  ss2_print_str(HEADER_TOKEN);
  ss2_print_str(",n=");
  ss2_print_i32((int32_t)N_BASE);
  ss2_print_str(",k=");
  ss2_print_i32((int32_t)K_BASE);
  ss2_print_str("\\r\\n");

  ss2_sa_disable();
  short_delay();
  ss2_sa_enable();
  short_delay();
  ss2_sa_soft_reset();

  uint32_t cfg = ss2_sa_make_config(ACT_PRECISION, WEIGHT_PRECISION,
                                    TILE_M, TILE_N, TILE_K, BATCH_COUNT);
  ss2_sa_write32(SS2_SA_OFF_CONFIG, cfg);
  ss2_sa_write32(SS2_SA_OFF_CONTROL, SS2_SA_CTRL_LOAD_WEIGHTS);

  if (ss2_sa_wait_phase(SS2_SA_PH_LOAD_WEIGHTS, 8000u, &status) != 0) {{
    ss2_print_str("HEADER_TILE_FAIL,load_weight_phase,status=");
    ss2_print_hex32(status);
    ss2_print_str("\\r\\n");
    errors++;
    print_tile_done(errors);
    while (1) {{}}
  }}

  for (uint32_t n = 0u; n < TILE_N; ++n) {{
    ss2_sa_stream_weight_vector(weights[n], WEIGHT_PRECISION, TILE_K);
  }}

  if (ss2_sa_wait_phase(SS2_SA_PH_BATCH_COMPUTE, 12000u, &status) != 0) {{
    ss2_print_str("HEADER_TILE_FAIL,compute_phase,status=");
    ss2_print_hex32(status);
    ss2_print_str("\\r\\n");
    errors++;
    print_tile_done(errors);
    while (1) {{}}
  }}

  for (uint32_t batch = 0u; batch < BATCH_COUNT; ++batch) {{
    for (uint32_t m = 0u; m < TILE_M; ++m) {{
      ss2_sa_stream_activation_vector(acts[batch][m], ACT_PRECISION, TILE_K);
    }}

    if (ss2_sa_wait_output_valid(30000u, &status) != 0) {{
      ss2_print_str("HEADER_TILE_FAIL,output_valid,status=");
      ss2_print_hex32(status);
      ss2_print_str("\\r\\n");
      errors++;
      break;
    }}

    uint32_t expected_words = TILE_M * TILE_N * 2u;
    if (ss2_sa_status_output_words(status) != expected_words) {{
      ss2_print_str("HEADER_TILE_FAIL,output_words,status=");
      ss2_print_hex32(status);
      ss2_print_str("\\r\\n");
      errors++;
    }}

    for (uint32_t m = 0u; m < TILE_M; ++m) {{
      for (uint32_t n = 0u; n < TILE_N; ++n) {{
        int64_t got = ss2_sa_read_output_elem(m, n, TILE_N);
        int64_t expected = expected_elem(batch, m, n);
        if (got != expected) {{
          if (errors < 4) {{
            ss2_print_str("HEADER_TILE_MISMATCH,b=");
            ss2_print_i32((int32_t)batch);
            ss2_print_str(",m=");
            ss2_print_i32((int32_t)m);
            ss2_print_str(",n=");
            ss2_print_i32((int32_t)n);
            ss2_print_str(",golden=");
            print_i64_hex(expected);
            ss2_print_str(",actual=");
            print_i64_hex(got);
            ss2_print_str("\\r\\n");
          }}
          errors++;
        }}
      }}
    }}

    ss2_sa_release_output();
    if ((batch + 1u) < BATCH_COUNT) {{
      if (ss2_sa_wait_phase(SS2_SA_PH_BATCH_COMPUTE, 12000u, &status) != 0) {{
        ss2_print_str("HEADER_TILE_FAIL,next_batch_phase,status=");
        ss2_print_hex32(status);
        ss2_print_str("\\r\\n");
        errors++;
        break;
      }}
    }} else {{
      if (ss2_sa_wait_phase(SS2_SA_PH_IDLE, 12000u, &status) != 0) {{
        ss2_print_str("HEADER_TILE_FAIL,idle_phase,status=");
        ss2_print_hex32(status);
        ss2_print_str("\\r\\n");
        errors++;
      }}
    }}
  }}

  print_tile_done(errors);
  while (1) {{}}
}}
"""


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


def compile_tile(
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
    obj_path = source_path.with_suffix(".o")
    crt_obj = work_dir / "crt0.o"
    link_script = work_dir / "link_header_tile.ld"

    if not link_script.exists():
        link_script.write_text(make_linker_script(), encoding="utf-8")

    cflags = [
        "-march=" + arch,
        "-D__riscv__",
        "-mabi=ilp32",
        "-Os",
        "-ffunction-sections",
        "-fdata-sections",
        "-I" + str(common_dir),
    ]

    run_command([cc, *cflags, "-c", str(source_path), "-o", str(obj_path)])
    run_command([cc, "-march=" + arch, "-D__riscv__", "-mabi=ilp32",
                 "-DLANGUAGE_ASSEBMLY", "-c", str(common_dir / "crt0.S"),
                 "-o", str(crt_obj)])
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
        "resume 0x01000000",
        "-c",
        f"sleep {wait_ms}",
        "-c",
        "shutdown",
    ], cwd=openocd_cfg.parents[1], log_path=log_path)


def run_tile_elf(
    *,
    repo: Path,
    uart_capture: Path,
    uart_dev: str,
    uart_baud: int,
    tile_timeout: int,
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
        str(tile_timeout),
        "--log",
        str(uart_log),
        "--pass-regex",
        r"HEADER_TILE_DONE,.*PASS",
        "--fail-regex",
        r"HEADER_TILE_DONE,.*FAIL|HEADER_TILE_FAIL|HEADER_TILE_MISMATCH",
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
        raise RuntimeError(f"UART tile run failed rc={rc}; see {uart_log}")


def header_range_is_valid(values: list[int], width: int) -> bool:
    lo, hi = signed_range(width)
    return min(values) >= lo and max(values) <= hi


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

    token = sanitize_token(header.stem)
    header_dir = work_dir / f"{header_idx:02d}_{token}"
    header_dir.mkdir(parents=True, exist_ok=True)

    act_range_ok = header_range_is_valid(a_full, act_bits)
    weight_range_ok = header_range_is_valid(w_full, weight_bits)
    expected_invalid = (not act_range_ok) or (not weight_range_ok) or (header.name in EXPECTED_INVALID_HEADERS)

    print(
        f"HEADER_BEGIN,{header_idx}/{total_headers},{header.name},"
        f"M={full_m},K={full_k},N={full_n},A={act_bits},W={weight_bits},"
        f"C={c_width},range_ok={int(act_range_ok and weight_range_ok)}",
        flush=True,
    )

    tile_count = 0
    for n_base in range(0, full_n, 8):
        for k_base in range(0, full_k, 8):
            weights = [
                [w_full[(n_base + n) * full_k + (k_base + k)] for k in range(8)]
                for n in range(8)
            ]
            act_batches = []
            for m_base in range(0, full_m, 8):
                act_batches.append([
                    [a_full[(m_base + m) * full_k + (k_base + k)] for k in range(8)]
                    for m in range(8)
                ])

            source = make_tile_source(
                header_token=token,
                n_base=n_base,
                k_base=k_base,
                act_bits=act_bits,
                weight_bits=weight_bits,
                weights=weights,
                act_batches=act_batches,
            )
            tile_name = f"{token}_n{n_base:02d}_k{k_base:02d}"
            source_path = header_dir / f"{tile_name}.c"
            elf_path = header_dir / f"{tile_name}.elf"
            source_path.write_text(source, encoding="utf-8")

            print(f"  TILE_BUILD_RUN,{header.name},n={n_base},k={k_base}", flush=True)
            compile_tile(
                repo=args.repo,
                work_dir=header_dir,
                source_path=source_path,
                elf_path=elf_path,
                arch=args.riscv_arch,
                cc=args.cc,
            )
            if not args.compile_only:
                run_tile_elf(
                    repo=args.repo,
                    uart_capture=args.uart_capture,
                    uart_dev=args.uart_dev,
                    uart_baud=args.uart_baud,
                    tile_timeout=args.tile_timeout,
                    openocd_cfg=args.openocd_cfg,
                    elf_path=elf_path,
                    wait_ms=args.elf_wait_ms,
                    log_prefix=header_dir / tile_name,
                )
            tile_count += 1

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

    fatal_mismatches = mismatches
    if expected_invalid and not args.include_invalid:
        fatal_mismatches = 0

    if mismatches:
        for m, n, expected, actual in samples:
            print(
                f"HEADER_MISMATCH_SAMPLE,{header.name},m={m},n={n},"
                f"golden={expected},actual={actual}",
                flush=True,
            )

    if mismatches and expected_invalid and not args.include_invalid:
        result = "EXPECTED_INVALID"
    else:
        result = "PASS" if mismatches == 0 else "FAIL"

    print(
        f"HEADER_DONE,{header.name},tiles={tile_count},matched={full_m * full_n - mismatches},"
        f"mismatches={mismatches},result={result}",
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
                        help="Generate and link tile ELFs, but do not touch hardware")
    parser.add_argument("--log-dir", type=Path,
                        default=repo_default / "build" / "fpga" / "ss2_header_sweep")
    parser.add_argument("--uart-dev", default="/dev/ttyACM0")
    parser.add_argument("--uart-baud", type=int, default=9600)
    parser.add_argument("--tile-timeout", type=int, default=25)
    parser.add_argument("--elf-wait-ms", type=int, default=12000)
    parser.add_argument("--openocd-cfg", type=Path,
                        default=repo_default / "fpga" / "utils" / "openocd-didactic-ft232h-z2.cfg")
    parser.add_argument("--uart-capture", type=Path,
                        default=repo_default / "fpga" / "scripts" / "uart_capture_until.py")
    parser.add_argument("--cc", default="riscv64-unknown-elf-gcc")
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
    if shutil.which("openocd") is None:
        print("ERROR: openocd not found", file=sys.stderr)
        return 2
    if not args.openocd_cfg.exists():
        print(f"ERROR: OpenOCD config not found: {args.openocd_cfg}", file=sys.stderr)
        return 2
    if not args.uart_capture.exists():
        print(f"ERROR: UART capture helper not found: {args.uart_capture}", file=sys.stderr)
        return 2

    include_dir = args.repo / "sw" / "gemm" / "include"
    headers = sorted(include_dir.glob(args.headers_glob))
    if args.limit_headers:
        headers = headers[: args.limit_headers]
    if not headers:
        print(f"ERROR: no headers matched {args.headers_glob!r} under {include_dir}", file=sys.stderr)
        return 2

    args.log_dir.mkdir(parents=True, exist_ok=True)
    work_dir = args.log_dir / "generated_tiles"
    work_dir.mkdir(parents=True, exist_ok=True)

    print("SS2 hardware full-header sweep", flush=True)
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
            print(f"HEADER_DONE,{header.name},tiles=unknown,matched=0,mismatches=unknown,result=FAIL", flush=True)
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
        "ALL_HEADERS_FINAL,"
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
