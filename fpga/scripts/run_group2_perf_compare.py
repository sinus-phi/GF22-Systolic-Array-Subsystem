#!/usr/bin/env python3
"""Benchmark CPU-only GEMM against GROUP2 subsystem GEMM on FPGA.

This runner is intentionally separate from the functional full-header runner.
It generates one temporary RISC-V ELF per selected GEMM header.  Each ELF:

  1. computes the full GEMM on the RISC-V CPU,
  2. computes the same GEMM through the GROUP2 subsystem,
  3. compares CPU, subsystem, and golden results,
  4. prints cycle counts through UART.

The FPGA bitstream is assumed to already contain the CPU + GROUP2 subsystem.
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import re
import subprocess
import sys
import time
from dataclasses import dataclass
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

static C_TYPE cpu_result[M_d * N_d];
static C_TYPE ss_result[M_d * N_d];
static int64_t ss_accum[M_d * N_d];

static uint64_t ss_weight_cycles;
static uint64_t ss_activation_cycles;
static uint64_t ss_output_wait_cycles;
static uint64_t ss_output_read_cycles;
static uint64_t ss_control_cycles;
static uint64_t ss_finalize_cycles;

static inline uint64_t bench_read_mcycle(void)
{
  uint32_t hi0;
  uint32_t lo;
  uint32_t hi1;

  do {
    asm volatile("csrr %0, mcycleh" : "=r"(hi0));
    asm volatile("csrr %0, mcycle" : "=r"(lo));
    asm volatile("csrr %0, mcycleh" : "=r"(hi1));
  } while (hi0 != hi1);

  return ((uint64_t)hi0 << 32) | (uint64_t)lo;
}

static void print_u64_hex(uint64_t value)
{
  group2_print_hex32((uint32_t)(value >> 32));
  group2_print_char('_');
  group2_print_hex32((uint32_t)value);
}

static void short_delay(void)
{
  for (volatile uint32_t i = 0; i < 1000u; ++i) {
    asm volatile("nop");
  }
}

static void clear_ss_accum(void)
{
  for (uint32_t i = 0u; i < (uint32_t)(M_d * N_d); ++i) {
    ss_accum[i] = 0;
    ss_result[i] = (C_TYPE)0;
  }
}

static void clear_counters(void)
{
  ss_weight_cycles = 0;
  ss_activation_cycles = 0;
  ss_output_wait_cycles = 0;
  ss_output_read_cycles = 0;
  ss_control_cycles = 0;
  ss_finalize_cycles = 0;
}

static int wait_or_report(uint32_t expected_phase, uint32_t timeout, const char *tag)
{
  uint32_t status = 0u;
  if (group2_sa_wait_phase(expected_phase, timeout, &status) == 0) {
    return 0;
  }

  group2_print_str("PERF_ERROR,");
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
    group2_print_str("PERF_ERROR,");
    group2_print_str(HEADER_TOKEN);
    group2_print_str(",");
    group2_print_str(tag);
    group2_print_str(",status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    return 1;
  }

  if (group2_sa_status_output_words(status) != (TILE_M * TILE_N * 2u)) {
    group2_print_str("PERF_ERROR,");
    group2_print_str(HEADER_TOKEN);
    group2_print_str(",bad_output_words,status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    return 1;
  }

  return 0;
}

static uint64_t run_cpu_gemm(void)
{
  uint64_t start = bench_read_mcycle();

  for (uint32_t m = 0u; m < M_d; ++m) {
    for (uint32_t n = 0u; n < N_d; ++n) {
      int64_t acc = 0;
      for (uint32_t k = 0u; k < K_d; ++k) {
        int32_t a = (int32_t)input_unpacked[m * K_d + k];
        int32_t w = (int32_t)weights_unpacked[n * K_d + k];
        acc += (int64_t)a * (int64_t)w;
      }
      cpu_result[m * N_d + n] = (C_TYPE)(acc + (int64_t)bias[n]);
    }
  }

  return bench_read_mcycle() - start;
}

static int run_ss_tile(uint32_t n_base, uint32_t k_base)
{
  int errors = 0;
  int32_t vec[TILE_K];
  uint64_t t0;
  uint64_t t1;

  t0 = bench_read_mcycle();
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
  t1 = bench_read_mcycle();
  ss_weight_cycles += t1 - t0;

  for (uint32_t m_base = 0u; m_base < M_d; m_base += TILE_M) {
    t0 = bench_read_mcycle();
    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t k = 0u; k < TILE_K; ++k) {
        vec[k] = (int32_t)input_unpacked[(m_base + m) * K_d + (k_base + k)];
      }
      group2_sa_stream_activation_vector(vec, ACT_PRECISION, TILE_K);
    }
    t1 = bench_read_mcycle();
    ss_activation_cycles += t1 - t0;

    t0 = bench_read_mcycle();
    if (wait_output_or_report("output_valid") != 0) {
      return 1;
    }
    t1 = bench_read_mcycle();
    ss_output_wait_cycles += t1 - t0;

    t0 = bench_read_mcycle();
    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t n = 0u; n < TILE_N; ++n) {
        uint32_t dst = (m_base + m) * N_d + (n_base + n);
        ss_accum[dst] += group2_sa_read_output_elem(m, n, TILE_N);
      }
    }
    t1 = bench_read_mcycle();
    ss_output_read_cycles += t1 - t0;

    t0 = bench_read_mcycle();
    group2_sa_release_output();
    if ((m_base + TILE_M) < M_d) {
      errors += wait_or_report(GROUP2_SA_PH_BATCH_COMPUTE, 16000u, "next_batch_phase");
    } else {
      errors += wait_or_report(GROUP2_SA_PH_IDLE, 16000u, "idle_phase");
    }
    t1 = bench_read_mcycle();
    ss_control_cycles += t1 - t0;

    if (errors != 0) {
      return errors;
    }
  }

  return errors;
}

static int run_ss_all_tiles(void)
{
  int errors = 0;

  for (uint32_t n_base = 0u; n_base < N_d; n_base += TILE_N) {
    for (uint32_t k_base = 0u; k_base < K_d; k_base += TILE_K) {
      errors += run_ss_tile(n_base, k_base);
      if (errors != 0) {
        group2_sa_soft_reset();
        return errors;
      }
    }
  }

  return errors;
}

static void finalize_ss_result(void)
{
  uint64_t t0 = bench_read_mcycle();
  for (uint32_t m = 0u; m < M_d; ++m) {
    for (uint32_t n = 0u; n < N_d; ++n) {
      uint32_t idx = m * N_d + n;
      ss_result[idx] = (C_TYPE)(ss_accum[idx] + (int64_t)bias[n]);
    }
  }
  ss_finalize_cycles += bench_read_mcycle() - t0;
}

static uint64_t run_ss_gemm(int *runtime_errors)
{
  uint64_t start;
  uint64_t elapsed;

  clear_ss_accum();
  clear_counters();

  group2_sa_disable();
  short_delay();
  group2_sa_enable();
  short_delay();
  group2_sa_soft_reset();

  start = bench_read_mcycle();
  *runtime_errors = run_ss_all_tiles();
  if (*runtime_errors == 0) {
    finalize_ss_result();
  }
  elapsed = bench_read_mcycle() - start;
  return elapsed;
}

static int compare_with_golden(const C_TYPE *values)
{
  int errors = 0;
  for (uint32_t i = 0u; i < (uint32_t)(M_d * N_d); ++i) {
    if (values[i] != golden[i]) {
      errors++;
    }
  }
  return errors;
}

static int compare_cpu_vs_ss(void)
{
  int errors = 0;
  for (uint32_t i = 0u; i < (uint32_t)(M_d * N_d); ++i) {
    if (cpu_result[i] != ss_result[i]) {
      errors++;
    }
  }
  return errors;
}

static void print_cycle_field(const char *name, uint64_t value)
{
  group2_print_str(",");
  group2_print_str(name);
  group2_print_str("=");
  print_u64_hex(value);
}

static void print_done(int cpu_mismatches,
                       int ss_runtime_errors,
                       int ss_mismatches,
                       int cpu_ss_mismatches)
{
  int golden_ok = (EXPECTED_INVALID != 0u) ||
                  ((cpu_mismatches == 0) && (ss_mismatches == 0));
  int ok = golden_ok &&
           (ss_runtime_errors == 0) &&
           (cpu_ss_mismatches == 0);

  group2_print_str("PERF_DONE,");
  group2_print_str(HEADER_TOKEN);
  group2_print_str(",cpu_mismatches=");
  group2_print_i32(cpu_mismatches);
  group2_print_str(",ss_runtime_errors=");
  group2_print_i32(ss_runtime_errors);
  group2_print_str(",ss_mismatches=");
  group2_print_i32(ss_mismatches);
  group2_print_str(",cpu_ss_mismatches=");
  group2_print_i32(cpu_ss_mismatches);
  group2_print_str(",expected_invalid=");
  group2_print_i32((int32_t)EXPECTED_INVALID);
  group2_print_str(",");
  group2_print_str(ok ? "PASS" : "FAIL");
  group2_print_str("\r\n");
}

int main(void)
{
  uint64_t cpu_cycles;
  uint64_t ss_cycles;
  int cpu_mismatches;
  int ss_mismatches = 0;
  int ss_runtime_errors = 0;
  int cpu_ss_mismatches = 0;

  group2_print_init();
  group2_print_str("\r\nPERF_BEGIN,");
  group2_print_str(HEADER_TOKEN);
  group2_print_str(",M=");
  group2_print_i32((int32_t)M_d);
  group2_print_str(",K=");
  group2_print_i32((int32_t)K_d);
  group2_print_str(",N=");
  group2_print_i32((int32_t)N_d);
  group2_print_str(",A_bits=");
  group2_print_i32((int32_t)@ACT_BITS@);
  group2_print_str(",W_bits=");
  group2_print_i32((int32_t)@WEIGHT_BITS@);
  group2_print_str(",expected_invalid=");
  group2_print_i32((int32_t)EXPECTED_INVALID);
  group2_print_str("\r\n");

  cpu_cycles = run_cpu_gemm();
  cpu_mismatches = compare_with_golden(cpu_result);
  group2_print_str("PERF_CPU,");
  group2_print_str(HEADER_TOKEN);
  print_cycle_field("cycles", cpu_cycles);
  group2_print_str(",mismatches=");
  group2_print_i32(cpu_mismatches);
  group2_print_str("\r\n");

  ss_cycles = run_ss_gemm(&ss_runtime_errors);
  if (ss_runtime_errors == 0) {
    ss_mismatches = compare_with_golden(ss_result);
    cpu_ss_mismatches = compare_cpu_vs_ss();
  }

  group2_print_str("PERF_SS,");
  group2_print_str(HEADER_TOKEN);
  print_cycle_field("cycles", ss_cycles);
  print_cycle_field("weight", ss_weight_cycles);
  print_cycle_field("activation", ss_activation_cycles);
  print_cycle_field("output_wait", ss_output_wait_cycles);
  print_cycle_field("output_read", ss_output_read_cycles);
  print_cycle_field("control", ss_control_cycles);
  print_cycle_field("finalize", ss_finalize_cycles);
  group2_print_str(",runtime_errors=");
  group2_print_i32(ss_runtime_errors);
  group2_print_str(",mismatches=");
  group2_print_i32(ss_mismatches);
  group2_print_str(",cpu_ss_mismatches=");
  group2_print_i32(cpu_ss_mismatches);
  group2_print_str("\r\n");

  print_done(cpu_mismatches, ss_runtime_errors, ss_mismatches, cpu_ss_mismatches);
  while (1) {}
}
'''


@dataclass
class PerfResult:
    header: str
    expected_invalid: bool
    cpu_cycles: int
    ss_cycles: int
    cpu_mismatches: int
    ss_mismatches: int
    ss_runtime_errors: int
    cpu_ss_mismatches: int
    result: str
    ss_weight_cycles: int = 0
    ss_activation_cycles: int = 0
    ss_output_wait_cycles: int = 0
    ss_output_read_cycles: int = 0
    ss_control_cycles: int = 0
    ss_finalize_cycles: int = 0


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


def parse_precision_bits(header: Path) -> tuple[int, int]:
    match = re.search(r"array_mode\d+_(\d+)b_(\d+)b_", header.name)
    if not match:
        raise ValueError(f"cannot infer precision from header name: {header.name}")
    return int(match.group(1)), int(match.group(2))


def signed_range(width: int) -> tuple[int, int]:
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def sanitize_token(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]+", "_", name).strip("_")


def header_range_is_valid(header: Path, act_bits: int, weight_bits: int) -> bool:
    a_full = parse_c_array(header, "input_unpacked")
    w_full = parse_c_array(header, "weights_unpacked")
    act_lo, act_hi = signed_range(act_bits)
    weight_lo, weight_hi = signed_range(weight_bits)
    return (act_lo <= min(a_full) <= max(a_full) <= act_hi) and (
        weight_lo <= min(w_full) <= max(w_full) <= weight_hi
    )


def is_expected_invalid(header: Path) -> bool:
    act_bits, weight_bits = parse_precision_bits(header)
    return header.name in EXPECTED_INVALID_HEADERS or not header_range_is_valid(header, act_bits, weight_bits)


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


def render_c_source(header: Path) -> str:
    act_bits, weight_bits = parse_precision_bits(header)
    if act_bits not in BITS_TO_PRECISION or weight_bits not in BITS_TO_PRECISION:
        raise ValueError(f"unsupported precision in {header.name}: A={act_bits}, W={weight_bits}")

    replacements = {
        "@HEADER_NAME@": header.name,
        "@HEADER_TOKEN@": sanitize_token(header.stem),
        "@ACT_PRECISION@": BITS_TO_PRECISION[act_bits],
        "@WEIGHT_PRECISION@": BITS_TO_PRECISION[weight_bits],
        "@ACT_BITS@": str(act_bits),
        "@WEIGHT_BITS@": str(weight_bits),
        "@EXPECTED_INVALID@": "1" if is_expected_invalid(header) else "0",
    }

    source = C_TEMPLATE
    for key, value in replacements.items():
        source = source.replace(key, value)
    return source


def run_command(args: list[str], *, cwd: Path | None = None, log_path: Path | None = None,
                check: bool = True, stdout=None, stderr=None) -> subprocess.CompletedProcess:
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("w", encoding="utf-8", errors="replace") as log:
            proc = subprocess.run(args, cwd=cwd, text=True, stdout=log, stderr=subprocess.STDOUT)
    else:
        proc = subprocess.run(args, cwd=cwd, text=True, stdout=stdout, stderr=stderr)
    if check and proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(args)}")
    return proc


def compile_header(*, repo: Path, work_dir: Path, source_path: Path, elf_path: Path,
                   arch: str, cc: str, opt: str) -> None:
    sw_dir = repo / "fpga" / "sw"
    common_dir = sw_dir / "common"
    include_dir = sw_dir / "gemm" / "include"
    obj_path = source_path.with_suffix(".o")
    crt_obj = work_dir / "crt0.o"
    link_script = work_dir / "link_perf.ld"

    if not link_script.exists():
        link_script.write_text(make_linker_script(), encoding="utf-8")

    cflags = [
        "-march=" + arch,
        "-D__riscv__",
        "-mabi=ilp32",
        opt,
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


def parse_cycle_hex(value: str) -> int:
    match = re.fullmatch(r"0x([0-9a-fA-F]{8})_0x([0-9a-fA-F]{8})", value.strip())
    if not match:
        raise ValueError(f"bad cycle value: {value!r}")
    return (int(match.group(1), 16) << 32) | int(match.group(2), 16)


def parse_optional_cycle_hex(value: str) -> int:
    try:
        return parse_cycle_hex(value)
    except ValueError:
        return -1


def parse_key_values(line: str) -> tuple[str, dict[str, str]]:
    parts = line.strip().split(",")
    return parts[0], dict(part.split("=", 1) for part in parts[2:] if "=" in part)


def parse_uart_result(header: Path, uart_log: Path) -> PerfResult:
    text = uart_log.read_text(encoding="utf-8", errors="replace")
    cpu_line = next((line for line in text.splitlines() if line.startswith("PERF_CPU,")), None)
    ss_line = next((line for line in text.splitlines() if line.startswith("PERF_SS,")), None)
    done_line = next((line for line in text.splitlines() if line.startswith("PERF_DONE,")), None)
    if cpu_line is None or ss_line is None or done_line is None:
        raise RuntimeError(f"missing PERF lines in {uart_log}")

    _, cpu = parse_key_values(cpu_line)
    _, ss = parse_key_values(ss_line)
    done_parts = done_line.strip().split(",")
    _, done = parse_key_values(done_line)
    result = done_parts[-1]

    return PerfResult(
        header=header.name,
        expected_invalid=done.get("expected_invalid", "0") == "1",
        cpu_cycles=parse_cycle_hex(cpu["cycles"]),
        ss_cycles=parse_cycle_hex(ss["cycles"]),
        cpu_mismatches=int(cpu.get("mismatches", "0")),
        ss_mismatches=int(ss.get("mismatches", "0")),
        ss_runtime_errors=int(ss.get("runtime_errors", "0")),
        cpu_ss_mismatches=int(ss.get("cpu_ss_mismatches", "0")),
        result=result,
        ss_weight_cycles=parse_optional_cycle_hex(ss.get("weight", "0x00000000_0x00000000")),
        ss_activation_cycles=parse_optional_cycle_hex(ss.get("activation", "0x00000000_0x00000000")),
        ss_output_wait_cycles=parse_optional_cycle_hex(ss.get("output_wait", "0x00000000_0x00000000")),
        ss_output_read_cycles=parse_optional_cycle_hex(ss.get("output_read", "0x00000000_0x00000000")),
        ss_control_cycles=parse_optional_cycle_hex(ss.get("control", "0x00000000_0x00000000")),
        ss_finalize_cycles=parse_optional_cycle_hex(ss.get("finalize", "0x00000000_0x00000000")),
    )


def latency_us(cycles: int, soc_clk_hz: int) -> float:
    return (cycles * 1_000_000.0) / float(soc_clk_hz)


def format_speedup(cpu_cycles: int, ss_cycles: int) -> str:
    if ss_cycles == 0:
        return "inf"
    return f"{cpu_cycles / ss_cycles:.3f}"


def append_summary(summary_csv: Path, result: PerfResult, soc_clk_hz: int) -> None:
    summary_csv.parent.mkdir(parents=True, exist_ok=True)
    new_file = not summary_csv.exists()
    with summary_csv.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "header",
            "result",
            "expected_invalid",
            "cpu_cycles",
            "cpu_latency_us",
            "ss_cycles",
            "ss_latency_us",
            "speedup",
            "cpu_mismatches",
            "ss_mismatches",
            "ss_runtime_errors",
            "cpu_ss_mismatches",
            "ss_weight_cycles",
            "ss_activation_cycles",
            "ss_output_wait_cycles",
            "ss_output_read_cycles",
            "ss_control_cycles",
            "ss_finalize_cycles",
        ])
        if new_file:
            writer.writeheader()
        writer.writerow({
            "header": result.header,
            "result": result.result,
            "expected_invalid": int(result.expected_invalid),
            "cpu_cycles": result.cpu_cycles,
            "cpu_latency_us": f"{latency_us(result.cpu_cycles, soc_clk_hz):.3f}",
            "ss_cycles": result.ss_cycles,
            "ss_latency_us": f"{latency_us(result.ss_cycles, soc_clk_hz):.3f}",
            "speedup": format_speedup(result.cpu_cycles, result.ss_cycles),
            "cpu_mismatches": result.cpu_mismatches,
            "ss_mismatches": result.ss_mismatches,
            "ss_runtime_errors": result.ss_runtime_errors,
            "cpu_ss_mismatches": result.cpu_ss_mismatches,
            "ss_weight_cycles": result.ss_weight_cycles,
            "ss_activation_cycles": result.ss_activation_cycles,
            "ss_output_wait_cycles": result.ss_output_wait_cycles,
            "ss_output_read_cycles": result.ss_output_read_cycles,
            "ss_control_cycles": result.ss_control_cycles,
            "ss_finalize_cycles": result.ss_finalize_cycles,
        })


def print_host_summary(result: PerfResult, soc_clk_hz: int) -> None:
    speedup = format_speedup(result.cpu_cycles, result.ss_cycles)
    winner = "SS" if result.ss_cycles < result.cpu_cycles else "CPU"
    print(
        "PERF_HOST_SUMMARY,"
        f"{result.header},"
        f"result={result.result},"
        f"cpu_cycles={result.cpu_cycles},"
        f"cpu_latency_us={latency_us(result.cpu_cycles, soc_clk_hz):.3f},"
        f"ss_cycles={result.ss_cycles},"
        f"ss_latency_us={latency_us(result.ss_cycles, soc_clk_hz):.3f},"
        f"speedup={speedup},"
        f"winner={winner},"
        f"cpu_mismatches={result.cpu_mismatches},"
        f"ss_mismatches={result.ss_mismatches},"
        f"cpu_ss_mismatches={result.cpu_ss_mismatches}",
        flush=True,
    )
    if result.ss_cycles >= result.cpu_cycles:
        print(
            "PERF_HOST_NOTE,"
            f"{result.header},"
            "SS end-to-end is slower here; this includes APB streaming, output reads, "
            "and CPU-side tiling/post-processing overhead.",
            flush=True,
        )
    else:
        print(
            "PERF_HOST_NOTE,"
            f"{result.header},"
            "SS end-to-end is faster for this header even with APB streaming and readback overhead included.",
            flush=True,
        )


def run_one_header(*, repo: Path, header: Path, index: int, total: int, work_root: Path,
                   uart_capture: Path, uart_dev: str, uart_baud: int, header_timeout: int,
                   openocd_cfg: Path, elf_wait_ms: int, cc: str, arch: str, opt: str,
                   compile_only: bool, soc_clk_hz: int, summary_csv: Path) -> PerfResult | None:
    token = sanitize_token(header.stem)
    work_dir = work_root / f"{index:02d}_{token}"
    work_dir.mkdir(parents=True, exist_ok=True)

    source_path = work_dir / f"{token}.c"
    elf_path = work_dir / f"{token}.elf"
    uart_log = work_dir / f"{token}.uart.log"
    openocd_log = work_dir / f"{token}.openocd.log"
    nucleo_log = work_dir / f"{token}.nucleo_reset.log"

    source_path.write_text(render_c_source(header), encoding="utf-8")
    compile_header(repo=repo, work_dir=work_dir, source_path=source_path, elf_path=elf_path,
                   arch=arch, cc=cc, opt=opt)

    if compile_only:
        print(f"PERF_COMPILE_DONE,{header.name},elf={elf_path}", flush=True)
        return None

    print(f"PERF_HEADER_BEGIN,{index}/{total},{header.name},elf={elf_path}", flush=True)

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
        r"PERF_DONE,.*PASS",
        "--fail-regex",
        r"PERF_ERROR|PERF_DONE,.*FAIL",
    ])
    time.sleep(0.4)
    reset_nucleo(nucleo_log)
    time.sleep(0.6)
    load_and_run_elf(openocd_cfg, elf_path, elf_wait_ms, openocd_log)
    rc = capture.wait()
    if rc != 0:
        raise RuntimeError(f"UART perf run failed rc={rc}; see {uart_log}")

    result = parse_uart_result(header, uart_log)
    append_summary(summary_csv, result, soc_clk_hz)
    print_host_summary(result, soc_clk_hz)
    print(
        f"PERF_HEADER_DONE,{header.name},result={result.result},"
        f"summary_csv={summary_csv},uart_log={uart_log},openocd_log={openocd_log}",
        flush=True,
    )
    return result


def select_headers(args: argparse.Namespace, repo: Path) -> list[Path]:
    include_dir = repo / "fpga" / "sw" / "gemm" / "include"
    headers = sorted(include_dir.glob(args.headers_glob))
    if not headers:
        raise RuntimeError(f"no headers matched {args.headers_glob!r} under {include_dir}")

    if args.mode == "all":
        return headers
    if args.mode == "single":
        if not args.header:
            raise RuntimeError("--mode single requires --header")
        requested = Path(args.header)
        if requested.is_file():
            return [requested.resolve()]
        matches = [h for h in headers if h.name == args.header or h.stem == args.header]
        if not matches:
            raise RuntimeError(f"header not found: {args.header}")
        return [matches[0]]
    if args.mode == "random":
        candidates = headers if args.include_invalid_random else [h for h in headers if not is_expected_invalid(h)]
        rng = random.Random(args.seed)
        return [rng.choice(candidates)]
    raise RuntimeError(f"unknown mode: {args.mode}")


def parse_args() -> argparse.Namespace:
    repo_default = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument("--mode", choices=["random", "single", "all"], default="random")
    parser.add_argument("--header", help="Header basename/path for --mode single")
    parser.add_argument("--headers-glob", default="array_mode*.h")
    parser.add_argument("--include-invalid-random", action="store_true",
                        help="Allow expected-invalid headers in random mode")
    parser.add_argument("--seed", type=int, default=None,
                        help="Random seed. Default chooses from system randomness.")
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--log-dir", type=Path,
                        default=repo_default / "build" / "fpga" / "group2_perf_compare")
    parser.add_argument("--uart-dev", default=os.getenv("UART_DEV", "/dev/ttyACM0"))
    parser.add_argument("--uart-baud", type=int, default=int(os.getenv("UART_BAUD", "9600")))
    parser.add_argument("--header-timeout", type=int, default=60)
    parser.add_argument("--elf-wait-ms", type=int, default=20000)
    parser.add_argument("--openocd-cfg", type=Path,
                        default=repo_default / "fpga" / "utils" / "openocd-didactic-ft232h-z2.cfg")
    parser.add_argument("--uart-capture", type=Path,
                        default=repo_default / "fpga" / "scripts" / "uart_capture_until.py")
    parser.add_argument("--cc", default=os.getenv("RISCV_CC", "riscv64-unknown-elf-gcc"))
    parser.add_argument("--riscv-arch", default=os.getenv("RISCV_ARCH", "rv32imc_zicsr"))
    parser.add_argument("--opt", default=os.getenv("PERF_OPT", "-O2"))
    parser.add_argument("--soc-clk-hz", type=int, default=int(os.getenv("SOC_CLK_HZ", "25000000")))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo = args.repo.resolve()
    headers = select_headers(args, repo)
    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    work_root = (args.log_dir / stamp / "generated_perf").resolve()
    summary_csv = work_root.parent / "perf_summary.csv"

    print("GROUP2 CPU-vs-subsystem GEMM perf compare", flush=True)
    print(f"mode={args.mode} headers={len(headers)} log_dir={work_root.parent}", flush=True)
    print(f"soc_clk_hz={args.soc_clk_hz}", flush=True)
    if args.mode == "random":
        print(f"random_seed={args.seed}", flush=True)

    results: list[PerfResult] = []
    for idx, header in enumerate(headers, start=1):
        result = run_one_header(
            repo=repo,
            header=header,
            index=idx,
            total=len(headers),
            work_root=work_root,
            uart_capture=args.uart_capture,
            uart_dev=args.uart_dev,
            uart_baud=args.uart_baud,
            header_timeout=args.header_timeout,
            openocd_cfg=args.openocd_cfg,
            elf_wait_ms=args.elf_wait_ms,
            cc=args.cc,
            arch=args.riscv_arch,
            opt=args.opt,
            compile_only=args.compile_only,
            soc_clk_hz=args.soc_clk_hz,
            summary_csv=summary_csv,
        )
        if result is not None:
            results.append(result)

    if args.compile_only:
        print(f"PERF_COMPILE_FINAL,headers={len(headers)},PASS", flush=True)
        return 0

    failed = [r for r in results if r.result != "PASS"]
    if results:
        valid = [r for r in results if not r.expected_invalid]
        avg_speedup = sum((r.cpu_cycles / r.ss_cycles) for r in valid if r.ss_cycles) / max(
            1, sum(1 for r in valid if r.ss_cycles)
        )
        print(
            "PERF_FINAL,"
            f"headers={len(results)},"
            f"failed={len(failed)},"
            f"valid_headers={len(valid)},"
            f"avg_valid_speedup={avg_speedup:.3f},"
            f"summary_csv={summary_csv},"
            f"{'PASS' if not failed else 'FAIL'}",
            flush=True,
        )
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
