#!/usr/bin/env python3
"""Benchmark CPU-only GEMM against GROUP2 subsystem GEMM on FPGA.

This runner is intentionally separate from the functional full-header runner.
It generates one temporary RISC-V ELF per selected GEMM header.  Each ELF:

  1. computes the full GEMM on the RISC-V CPU,
  2. computes the same GEMM through the GROUP2 subsystem,
  3. compares CPU, subsystem, and golden results,
  4. reports both first-call (cold) and initialized repeated-call cycle counts.

The FPGA bitstream is assumed to already contain the CPU + GROUP2 subsystem.
"""

from __future__ import annotations

import argparse
import csv
import os
import random
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


BITS_TO_PRECISION = {
    4: "GROUP2_SA_DTYPE_INT4",
    8: "GROUP2_SA_DTYPE_INT8",
    16: "GROUP2_SA_DTYPE_INT16",
    32: "GROUP2_SA_DTYPE_INT16",
}

EXPECTED_INVALID_HEADERS = {
    "array_mode6_8b_4b_32_32_32_row-index.h",
}


C_TEMPLATE = r'''#include <stdint.h>
#include "group2_sa.h"
#include "group2_uart_print.h"
#include "@HEADER_NAME@"

#define ACT_PRECISION @ACT_PRECISION@
#define WEIGHT_PRECISION @WEIGHT_PRECISION@
#define EXPECTED_INVALID @EXPECTED_INVALID@u
#define HEADER_TOKEN "@HEADER_TOKEN@"
#define BENCH_REPETITIONS @BENCH_REPETITIONS@u
#define BENCH_WARMUPS @BENCH_WARMUPS@u
#define ACT_WORDS_PER_VECTOR @ACT_WORDS_PER_VECTOR@u
#define WEIGHT_WORDS_PER_VECTOR @WEIGHT_WORDS_PER_VECTOR@u
#define ACT_EFFECTIVE_BITS @ACT_EFFECTIVE_BITS@u
#define WEIGHT_EFFECTIVE_BITS @WEIGHT_EFFECTIVE_BITS@u
#define RESULT_WORDS_PER_ROW ((N_d + 1u) / 2u)

static uint16_t cpu_result[M_d * N_d];
static uint32_t ss_result_words[M_d * RESULT_WORDS_PER_ROW];
static uint64_t cpu_cold_cycles;
static uint64_t ss_cold_cycles;
static uint64_t ss_session_init_cycles;
static uint64_t cpu_samples[BENCH_REPETITIONS];
static uint64_t ss_samples[BENCH_REPETITIONS];

static inline uint64_t bench_read_mcycle(void)
{
  uint32_t hi0, lo, hi1;
  asm volatile("fence rw, rw" ::: "memory");
  do {
    asm volatile("csrr %0, mcycleh" : "=r"(hi0));
    asm volatile("csrr %0, mcycle" : "=r"(lo));
    asm volatile("csrr %0, mcycleh" : "=r"(hi1));
  } while (hi0 != hi1);
  asm volatile("fence rw, rw" ::: "memory");
  return ((uint64_t)hi0 << 32) | lo;
}

static uint64_t measure_timer_overhead(void)
{
  uint64_t best = ~(uint64_t)0;
  for (uint32_t i = 0u; i < 32u; ++i) {
    uint64_t start = bench_read_mcycle();
    uint64_t delta = bench_read_mcycle() - start;
    if (delta < best) best = delta;
  }
  return best;
}

static uint64_t sort_and_median(uint64_t *values)
{
  for (uint32_t i = 1u; i < BENCH_REPETITIONS; ++i) {
    uint64_t value = values[i];
    uint32_t j = i;
    while (j > 0u && values[j - 1u] > value) {
      values[j] = values[j - 1u];
      --j;
    }
    values[j] = value;
  }
  return values[BENCH_REPETITIONS / 2u];
}

static void print_u64_hex(uint64_t value)
{
  group2_print_hex32((uint32_t)(value >> 32));
  group2_print_char('_');
  group2_print_hex32((uint32_t)value);
}

static void short_delay(void)
{
  for (volatile uint32_t i = 0; i < 1000u; ++i) asm volatile("nop");
}

static int validate_inputs(void)
{
  for (uint32_t i = 0u; i < (uint32_t)(M_d * K_d); ++i)
    if (!group2_sa_value_fits((int32_t)input_unpacked[i], ACT_PRECISION)) return -1;
  for (uint32_t i = 0u; i < (uint32_t)(N_d * K_d); ++i)
    if (!group2_sa_value_fits((int32_t)weights_unpacked[i], WEIGHT_PRECISION)) return -1;
  for (uint32_t n = 0u; n < N_d; ++n)
    if (bias[n] < -32768 || bias[n] > 32767) return -1;
  return 0;
}

static int wait_phase(uint32_t phase, const char *tag)
{
  uint32_t status = 0u;
  if (group2_sa_wait_phase(phase, 60000u, &status) == 0) return 0;
  group2_print_str("PERF_ERROR,"); group2_print_str(HEADER_TOKEN);
  group2_print_str(","); group2_print_str(tag); group2_print_str(",status=");
  group2_print_hex32(status); group2_print_str("\r\n");
  return 1;
}

static void stream_runtime_weights(const W_TYPE *source, uint32_t k_base)
{
  const uint32_t elems_per_word = 32u / WEIGHT_EFFECTIVE_BITS;
  const uint32_t mask = (1u << WEIGHT_EFFECTIVE_BITS) - 1u;

  for (uint32_t n = 0u; n < GROUP2_SA_LOGICAL_N; ++n) {
    for (uint32_t word = 0u; word < WEIGHT_WORDS_PER_VECTOR; ++word) {
      uint32_t packed = 0u;
      for (uint32_t lane = 0u; lane < elems_per_word; ++lane) {
        uint32_t k = k_base + word * elems_per_word + lane;
        int32_t value = (n < N_d && k < K_d) ? (int32_t)source[n * K_d + k] : 0;
        packed |= ((uint32_t)value & mask) << (lane * WEIGHT_EFFECTIVE_BITS);
      }
      group2_sa_write32(GROUP2_SA_WEIGHT_DATA, packed);
    }
  }
}

static void stream_runtime_activations(const I_TYPE *source, uint32_t k_base)
{
  const uint32_t elems_per_word = 32u / ACT_EFFECTIVE_BITS;
  const uint32_t mask = (1u << ACT_EFFECTIVE_BITS) - 1u;

  for (uint32_t m = 0u; m < M_d; ++m) {
    for (uint32_t word = 0u; word < ACT_WORDS_PER_VECTOR; ++word) {
      uint32_t packed = 0u;
      for (uint32_t lane = 0u; lane < elems_per_word; ++lane) {
        uint32_t k = k_base + word * elems_per_word + lane;
        int32_t value = (k < K_d) ? (int32_t)source[m * K_d + k] : 0;
        packed |= ((uint32_t)value & mask) << (lane * ACT_EFFECTIVE_BITS);
      }
      group2_sa_write32(GROUP2_SA_ACT_DATA, packed);
    }
  }
}

static int initialize_ss_session(void)
{
  uint32_t status = 0u;

  group2_sa_disable(); short_delay(); group2_sa_enable(); short_delay();
  group2_sa_soft_reset();
  if (group2_sa_wait_phase(GROUP2_SA_PH_IDLE, 60000u, &status) != 0) return 1;

  for (uint32_t pair = 0u; pair < 16u; ++pair) {
    int16_t lo = (pair * 2u < N_d) ? (int16_t)bias[pair * 2u] : 0;
    int16_t hi = (pair * 2u + 1u < N_d) ? (int16_t)bias[pair * 2u + 1u] : 0;
    group2_sa_write_bias_pair(pair, lo, hi);
  }
  group2_sa_write32(GROUP2_SA_OFF_CONFIG,
                    group2_sa_make_config(ACT_PRECISION, WEIGHT_PRECISION, M_d, 1u));
  return 0;
}

static void run_cpu_gemm(void)
{
  for (uint32_t m = 0u; m < M_d; ++m) {
    for (uint32_t n = 0u; n < N_d; ++n) {
      uint16_t acc = (uint16_t)bias[n];
      for (uint32_t k = 0u; k < K_d; ++k) {
        int16_t a = (int16_t)input_unpacked[m * K_d + k];
        int16_t w = (int16_t)weights_unpacked[n * K_d + k];
        acc = group2_sa_add_wrap16(acc, group2_sa_mul_wrap16(a, w));
      }
      cpu_result[m * N_d + n] = acc;
    }
  }
}

static int run_ss_k_tile_fast(uint32_t k_base, uint32_t first)
{
  group2_sa_write32(GROUP2_SA_OFF_CONTROL,
                    first ? GROUP2_SA_CTRL_START_GEMM : GROUP2_SA_CTRL_START_GACC);
  if (wait_phase(GROUP2_SA_PH_WEIGHT, "weight_phase")) return 1;
  stream_runtime_weights(weights_unpacked, k_base);
  if (wait_phase(GROUP2_SA_PH_ACTIVATION, "activation_phase")) return 1;
  stream_runtime_activations(input_unpacked, k_base);
  return wait_phase(GROUP2_SA_PH_OUTPUT, "output_phase");
}

static int run_ss_gemm_fast(void)
{
  uint32_t first = 1u;
  for (uint32_t k = 0u; k < K_d; k += GROUP2_SA_K_TILE) {
    if (run_ss_k_tile_fast(k, first)) return 1;
    first = 0u;
  }

  group2_sa_read_output_words(M_d, RESULT_WORDS_PER_ROW, ss_result_words);
  group2_sa_release_context();
  return 0;
}

static uint16_t ss_result_elem(uint32_t row, uint32_t col)
{
  uint32_t word = ss_result_words[row * RESULT_WORDS_PER_ROW + (col >> 1)];
  return (uint16_t)((col & 1u) ? group2_sa_output_word_high(word)
                               : group2_sa_output_word_low(word));
}

static int compare_cpu_with_golden(void)
{
  int errors = 0;
  for (uint32_t i = 0u; i < (uint32_t)(M_d * N_d); ++i)
    if (cpu_result[i] != (uint16_t)golden[i]) errors++;
  return errors;
}

static int compare_ss_with_golden(void)
{
  int errors = 0;
  for (uint32_t m = 0u; m < M_d; ++m)
    for (uint32_t n = 0u; n < N_d; ++n)
      if (ss_result_elem(m, n) != (uint16_t)golden[m * N_d + n]) errors++;
  return errors;
}

static int compare_cpu_vs_ss(void)
{
  int errors = 0;
  for (uint32_t m = 0u; m < M_d; ++m)
    for (uint32_t n = 0u; n < N_d; ++n)
      if (cpu_result[m * N_d + n] != ss_result_elem(m, n)) errors++;
  return errors;
}

static void print_cycle_field(const char *name, uint64_t value)
{
  group2_print_str(","); group2_print_str(name); group2_print_str("=");
  print_u64_hex(value);
}

static void print_done(int cpu_mismatches, int ss_runtime_errors,
                       int ss_mismatches, int cpu_ss_mismatches, int invalid_input)
{
  int ok = invalid_input ? EXPECTED_INVALID :
      ((cpu_mismatches == 0) && (ss_runtime_errors == 0) &&
       (ss_mismatches == 0) && (cpu_ss_mismatches == 0));
  group2_print_str("PERF_DONE,"); group2_print_str(HEADER_TOKEN);
  group2_print_str(",cpu_mismatches="); group2_print_i32(cpu_mismatches);
  group2_print_str(",ss_runtime_errors="); group2_print_i32(ss_runtime_errors);
  group2_print_str(",ss_mismatches="); group2_print_i32(ss_mismatches);
  group2_print_str(",cpu_ss_mismatches="); group2_print_i32(cpu_ss_mismatches);
  group2_print_str(",expected_invalid="); group2_print_i32((int32_t)EXPECTED_INVALID);
  group2_print_str(","); group2_print_str(ok ? "PASS" : "FAIL");
  group2_print_str("\r\n");
}

int main(void)
{
  int invalid_input;
  int cpu_mismatches = 0, ss_mismatches = 0, ss_runtime_errors = 0;
  int cpu_ss_mismatches = 0;
  uint64_t cpu_cycles = 0, ss_cycles = 0, timer_overhead;
  uint64_t cpu_min = 0, cpu_max = 0, ss_min = 0, ss_max = 0;
  group2_print_init();
  group2_print_str("\r\nPERF_BEGIN,"); group2_print_str(HEADER_TOKEN);
  group2_print_str(",M="); group2_print_i32(M_d);
  group2_print_str(",K="); group2_print_i32(K_d);
  group2_print_str(",N="); group2_print_i32(N_d);
  group2_print_str(",A_bits="); group2_print_i32(@ACT_BITS@);
  group2_print_str(",W_bits="); group2_print_i32(@WEIGHT_BITS@);
  group2_print_str(",expected_invalid="); group2_print_i32(EXPECTED_INVALID);
  group2_print_str("\r\n");

  timer_overhead = measure_timer_overhead();
  invalid_input = validate_inputs() != 0;
  if (!invalid_input) {
    uint64_t start;
    int errors;

    start = bench_read_mcycle();
    (void)run_cpu_gemm();
    cpu_cold_cycles = bench_read_mcycle() - start;
    errors = compare_cpu_with_golden();
    if (errors > cpu_mismatches) cpu_mismatches = errors;

    start = bench_read_mcycle();
    errors = initialize_ss_session();
    if (!errors) errors = run_ss_gemm_fast();
    ss_cold_cycles = bench_read_mcycle() - start;
    if (errors) ss_runtime_errors = 1;
    else {
      errors = compare_ss_with_golden();
      if (errors > ss_mismatches) ss_mismatches = errors;
      errors = compare_cpu_vs_ss();
      if (errors > cpu_ss_mismatches) cpu_ss_mismatches = errors;
    }
  }
  if (!invalid_input && !ss_runtime_errors) {
    for (uint32_t warmup = 0u; warmup < BENCH_WARMUPS; ++warmup) {
      int errors;
      (void)run_cpu_gemm();
      errors = compare_cpu_with_golden();
      if (errors > cpu_mismatches) cpu_mismatches = errors;
      errors = run_ss_gemm_fast();
      if (errors) ss_runtime_errors = 1;
      else {
        errors = compare_ss_with_golden();
        if (errors > ss_mismatches) ss_mismatches = errors;
        errors = compare_cpu_vs_ss();
        if (errors > cpu_ss_mismatches) cpu_ss_mismatches = errors;
      }
    }

    for (uint32_t run = 0u; run < BENCH_REPETITIONS && !ss_runtime_errors; ++run) {
      int errors;
      uint64_t cpu_start = bench_read_mcycle();
      run_cpu_gemm();
      cpu_samples[run] = bench_read_mcycle() - cpu_start;
      errors = compare_cpu_with_golden();
      if (errors > cpu_mismatches) cpu_mismatches = errors;

      uint64_t start = bench_read_mcycle();
      errors = run_ss_gemm_fast();
      ss_samples[run] = bench_read_mcycle() - start;
      if (errors) {
        ss_runtime_errors = 1;
        break;
      }
      errors = compare_ss_with_golden();
      if (errors > ss_mismatches) ss_mismatches = errors;
      errors = compare_cpu_vs_ss();
      if (errors > cpu_ss_mismatches) cpu_ss_mismatches = errors;

    }

    if (!ss_runtime_errors) {
      cpu_cycles = sort_and_median(cpu_samples);
      ss_cycles = sort_and_median(ss_samples);
      cpu_min = cpu_samples[0]; cpu_max = cpu_samples[BENCH_REPETITIONS - 1u];
      ss_min = ss_samples[0]; ss_max = ss_samples[BENCH_REPETITIONS - 1u];
      ss_session_init_cycles =
          (ss_cold_cycles > ss_cycles) ? (ss_cold_cycles - ss_cycles) : 0u;
    }
  }

  group2_print_str("PERF_META,"); group2_print_str(HEADER_TOKEN);
  group2_print_str(",input_contract=runtime_fused_stream");
  group2_print_str(",output_contract=packed_u32_pairs");
  group2_print_str(",init_contract=one_time_session");
  group2_print_str(",repetitions="); group2_print_i32(BENCH_REPETITIONS);
  group2_print_str(",warmups="); group2_print_i32(BENCH_WARMUPS);
  group2_print_str(",samples=");
  group2_print_i32(invalid_input ? 0 : (int32_t)BENCH_REPETITIONS);
  print_cycle_field("timer_overhead", timer_overhead);
  group2_print_str("\r\n");
  group2_print_str("PERF_CPU,"); group2_print_str(HEADER_TOKEN);
  print_cycle_field("cycles", cpu_cycles);
  print_cycle_field("cold", cpu_cold_cycles);
  print_cycle_field("min", cpu_min); print_cycle_field("max", cpu_max);
  group2_print_str(",mismatches="); group2_print_i32(cpu_mismatches);
  group2_print_str("\r\nPERF_SS,"); group2_print_str(HEADER_TOKEN);
  print_cycle_field("cycles", ss_cycles);
  print_cycle_field("cold", ss_cold_cycles);
  print_cycle_field("session_init", ss_session_init_cycles);
  print_cycle_field("min", ss_min); print_cycle_field("max", ss_max);
  group2_print_str(",runtime_errors="); group2_print_i32(ss_runtime_errors);
  group2_print_str(",mismatches="); group2_print_i32(ss_mismatches);
  group2_print_str(",cpu_ss_mismatches="); group2_print_i32(cpu_ss_mismatches);
  group2_print_str("\r\n");
  print_done(cpu_mismatches, ss_runtime_errors, ss_mismatches,
             cpu_ss_mismatches, invalid_input);
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
    input_contract: str
    output_contract: str
    init_contract: str
    repetitions: int
    warmups: int
    timer_overhead_cycles: int
    sample_count: int
    cpu_min_cycles: int
    cpu_max_cycles: int
    ss_min_cycles: int
    ss_max_cycles: int
    cpu_cold_cycles: int = 0
    ss_cold_cycles: int = 0
    ss_session_init_cycles: int = 0


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


def effective_precision_bits(width: int) -> int:
    return 16 if width == 32 else width


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


def render_c_source(header: Path, repetitions: int, warmups: int) -> str:
    act_bits, weight_bits = parse_precision_bits(header)
    if act_bits not in BITS_TO_PRECISION or weight_bits not in BITS_TO_PRECISION:
        raise ValueError(f"unsupported precision in {header.name}: A={act_bits}, W={weight_bits}")

    act_effective_bits = effective_precision_bits(act_bits)
    weight_effective_bits = effective_precision_bits(weight_bits)
    act_words = act_effective_bits // 4
    weight_words = weight_effective_bits // 4
    replacements = {
        "@HEADER_NAME@": header.name,
        "@HEADER_TOKEN@": sanitize_token(header.stem),
        "@ACT_PRECISION@": BITS_TO_PRECISION[act_bits],
        "@WEIGHT_PRECISION@": BITS_TO_PRECISION[weight_bits],
        "@ACT_BITS@": str(act_bits),
        "@WEIGHT_BITS@": str(weight_bits),
        "@EXPECTED_INVALID@": "1" if is_expected_invalid(header) else "0",
        "@BENCH_REPETITIONS@": str(repetitions),
        "@BENCH_WARMUPS@": str(warmups),
        "@ACT_WORDS_PER_VECTOR@": str(act_words),
        "@WEIGHT_WORDS_PER_VECTOR@": str(weight_words),
        "@ACT_EFFECTIVE_BITS@": str(act_effective_bits),
        "@WEIGHT_EFFECTIVE_BITS@": str(weight_effective_bits),
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


def load_and_run_elf(
    openocd_cfg: Path,
    elf_path: Path,
    wait_ms: int,
    log_path: Path,
    max_attempts: int,
    timeout_s: int,
) -> None:
    failures: list[str] = []
    for attempt in range(1, max_attempts + 1):
        attempt_log = log_path.with_name(f"{log_path.stem}.attempt{attempt}{log_path.suffix}")
        proc = run_command([
            "timeout",
            "--signal=KILL",
            f"{timeout_s}s",
            "openocd",
            "-f",
            str(openocd_cfg),
            "-c",
            "halt",
            "-c",
            f"load_image {elf_path}",
            "-c",
            f"verify_image {elf_path}",
            "-c",
            "resume 0x01000080",
            "-c",
            f"sleep {wait_ms}",
            "-c",
            "shutdown",
        ], cwd=openocd_cfg.parents[1], log_path=attempt_log, check=False)

        log_text = attempt_log.read_text(encoding="utf-8", errors="replace")
        verified = bool(re.search(r"^verified\s+\d+\s+bytes", log_text, flags=re.M))
        if proc.returncode == 0 and verified:
            shutil.copyfile(attempt_log, log_path)
            return

        failures.append(
            f"attempt {attempt}: rc={proc.returncode}, verified={int(verified)}, log={attempt_log}"
        )
        time.sleep(0.25)

    raise RuntimeError("OpenOCD ELF load/verify failed: " + "; ".join(failures))


def parse_cycle_hex(value: str) -> int:
    match = re.fullmatch(r"0x([0-9a-fA-F]{8})_0x([0-9a-fA-F]{8})", value.strip())
    if not match:
        raise ValueError(f"bad cycle value: {value!r}")
    return (int(match.group(1), 16) << 32) | int(match.group(2), 16)


def parse_key_values(line: str) -> tuple[str, dict[str, str]]:
    parts = line.strip().split(",")
    return parts[0], dict(part.split("=", 1) for part in parts[2:] if "=" in part)


def parse_uart_result(header: Path, uart_log: Path) -> PerfResult:
    text = uart_log.read_text(encoding="utf-8", errors="replace")
    token = sanitize_token(header.stem)
    last_begin = text.rfind(f"PERF_BEGIN,{token},")
    if last_begin >= 0:
        text = text[last_begin:]
    lines = text.splitlines()
    meta_lines = [line for line in lines if line.startswith(f"PERF_META,{token},")]
    cpu_lines = [line for line in lines if line.startswith(f"PERF_CPU,{token},")]
    ss_lines = [line for line in lines if line.startswith(f"PERF_SS,{token},")]
    done_lines = [line for line in lines if line.startswith(f"PERF_DONE,{token},")]
    if not meta_lines or not cpu_lines or not ss_lines or not done_lines:
        raise RuntimeError(f"missing PERF lines in {uart_log}")

    meta_line = meta_lines[-1]
    cpu_line = cpu_lines[-1]
    ss_line = ss_lines[-1]
    done_line = done_lines[-1]
    _, meta = parse_key_values(meta_line)
    _, cpu = parse_key_values(cpu_line)
    _, ss = parse_key_values(ss_line)
    done_parts = done_line.strip().split(",")
    _, done = parse_key_values(done_line)
    result = done_parts[-1]

    required_meta = {
        "input_contract", "output_contract", "init_contract", "repetitions",
        "warmups", "samples", "timer_overhead",
    }
    required_cpu = {"cycles", "cold", "min", "max", "mismatches"}
    required_ss = {
        "cycles", "cold", "session_init", "min", "max", "runtime_errors",
        "mismatches", "cpu_ss_mismatches",
    }
    missing = (
        {f"meta.{key}" for key in required_meta - meta.keys()}
        | {f"cpu.{key}" for key in required_cpu - cpu.keys()}
        | {f"ss.{key}" for key in required_ss - ss.keys()}
    )
    if missing:
        raise RuntimeError(f"missing PERF fields in {uart_log}: {', '.join(sorted(missing))}")

    repetitions = int(meta["repetitions"])
    expected_invalid = done.get("expected_invalid", "0") == "1"
    sample_count = int(meta["samples"])

    parsed = PerfResult(
        header=header.name,
        expected_invalid=expected_invalid,
        cpu_cycles=parse_cycle_hex(cpu["cycles"]),
        ss_cycles=parse_cycle_hex(ss["cycles"]),
        cpu_mismatches=int(cpu.get("mismatches", "0")),
        ss_mismatches=int(ss.get("mismatches", "0")),
        ss_runtime_errors=int(ss.get("runtime_errors", "0")),
        cpu_ss_mismatches=int(ss.get("cpu_ss_mismatches", "0")),
        result=result,
        input_contract=meta["input_contract"],
        output_contract=meta.get("output_contract", "unpacked_u16"),
        init_contract=meta.get("init_contract", "per_call_reset"),
        repetitions=repetitions,
        warmups=int(meta["warmups"]),
        timer_overhead_cycles=parse_cycle_hex(meta["timer_overhead"]),
        sample_count=sample_count,
        cpu_min_cycles=parse_cycle_hex(cpu["min"]),
        cpu_max_cycles=parse_cycle_hex(cpu["max"]),
        ss_min_cycles=parse_cycle_hex(ss["min"]),
        ss_max_cycles=parse_cycle_hex(ss["max"]),
        cpu_cold_cycles=parse_cycle_hex(cpu["cold"]),
        ss_cold_cycles=parse_cycle_hex(ss["cold"]),
        ss_session_init_cycles=parse_cycle_hex(ss["session_init"]),
    )
    if not expected_invalid:
        if sample_count != repetitions:
            raise RuntimeError(f"sample count mismatch in {uart_log}: {sample_count} != {repetitions}")
        if not (
            0 < parsed.cpu_min_cycles <= parsed.cpu_cycles <= parsed.cpu_max_cycles
            and 0 < parsed.ss_min_cycles <= parsed.ss_cycles <= parsed.ss_max_cycles
            and parsed.cpu_cold_cycles > 0
            and parsed.ss_cold_cycles > 0
        ):
            raise RuntimeError(f"invalid cycle ordering in {uart_log}")
    return parsed


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
            "input_contract",
            "output_contract",
            "init_contract",
            "repetitions",
            "warmups",
            "sample_count",
            "timer_overhead_cycles",
            "cpu_cycles",
            "cpu_cold_cycles",
            "cpu_min_cycles",
            "cpu_max_cycles",
            "cpu_latency_us",
            "cpu_cold_latency_us",
            "ss_cycles",
            "ss_min_cycles",
            "ss_max_cycles",
            "ss_latency_us",
            "ss_session_init_cycles",
            "ss_cold_cycles",
            "ss_cold_latency_us",
            "speedup",
            "cold_speedup",
            "cpu_mismatches",
            "ss_mismatches",
            "ss_runtime_errors",
            "cpu_ss_mismatches",
        ])
        if new_file:
            writer.writeheader()
        writer.writerow({
            "header": result.header,
            "result": result.result,
            "expected_invalid": int(result.expected_invalid),
            "input_contract": result.input_contract,
            "output_contract": result.output_contract,
            "init_contract": result.init_contract,
            "repetitions": result.repetitions,
            "warmups": result.warmups,
            "sample_count": result.sample_count,
            "timer_overhead_cycles": result.timer_overhead_cycles,
            "cpu_cycles": result.cpu_cycles,
            "cpu_cold_cycles": result.cpu_cold_cycles,
            "cpu_min_cycles": result.cpu_min_cycles,
            "cpu_max_cycles": result.cpu_max_cycles,
            "cpu_latency_us": f"{latency_us(result.cpu_cycles, soc_clk_hz):.3f}",
            "cpu_cold_latency_us": f"{latency_us(result.cpu_cold_cycles, soc_clk_hz):.3f}",
            "ss_cycles": result.ss_cycles,
            "ss_min_cycles": result.ss_min_cycles,
            "ss_max_cycles": result.ss_max_cycles,
            "ss_latency_us": f"{latency_us(result.ss_cycles, soc_clk_hz):.3f}",
            "ss_session_init_cycles": result.ss_session_init_cycles,
            "ss_cold_cycles": result.ss_cold_cycles,
            "ss_cold_latency_us": f"{latency_us(result.ss_cold_cycles, soc_clk_hz):.3f}",
            "speedup": "N/A" if result.expected_invalid else format_speedup(
                result.cpu_cycles, result.ss_cycles
            ),
            "cold_speedup": "N/A" if result.expected_invalid else format_speedup(
                result.cpu_cold_cycles, result.ss_cold_cycles
            ),
            "cpu_mismatches": result.cpu_mismatches,
            "ss_mismatches": result.ss_mismatches,
            "ss_runtime_errors": result.ss_runtime_errors,
            "cpu_ss_mismatches": result.cpu_ss_mismatches,
        })


def print_host_summary(result: PerfResult, soc_clk_hz: int) -> None:
    if result.expected_invalid:
        print(
            "PERF_HOST_SUMMARY,"
            f"{result.header},"
            f"result={result.result},"
            f"input_contract={result.input_contract},"
            f"output_contract={result.output_contract},"
            f"init_contract={result.init_contract},"
            "expected_invalid=1,measured=0,speedup=N/A",
            flush=True,
        )
        print(
            f"PERF_HOST_NOTE,{result.header},input rejected before timing; excluded from speedup.",
            flush=True,
        )
        return
    speedup = format_speedup(result.cpu_cycles, result.ss_cycles)
    winner = "SS" if result.ss_cycles < result.cpu_cycles else "CPU"
    print(
        "PERF_HOST_SUMMARY,"
        f"{result.header},"
        f"result={result.result},"
        f"input_contract={result.input_contract},"
        f"output_contract={result.output_contract},"
        f"init_contract={result.init_contract},"
        f"cpu_cold_cycles={result.cpu_cold_cycles},"
        f"cpu_cold_latency_us={latency_us(result.cpu_cold_cycles, soc_clk_hz):.3f},"
        f"cpu_cycles={result.cpu_cycles},"
        f"cpu_range={result.cpu_min_cycles}:{result.cpu_max_cycles},"
        f"cpu_latency_us={latency_us(result.cpu_cycles, soc_clk_hz):.3f},"
        f"ss_cycles={result.ss_cycles},"
        f"ss_range={result.ss_min_cycles}:{result.ss_max_cycles},"
        f"ss_latency_us={latency_us(result.ss_cycles, soc_clk_hz):.3f},"
        f"ss_session_init_cycles={result.ss_session_init_cycles},"
        f"ss_cold_cycles={result.ss_cold_cycles},"
        f"ss_cold_latency_us={latency_us(result.ss_cold_cycles, soc_clk_hz):.3f},"
        f"speedup={speedup},"
        f"cold_speedup={format_speedup(result.cpu_cold_cycles, result.ss_cold_cycles)},"
        f"repetitions={result.repetitions},"
        f"timer_overhead={result.timer_overhead_cycles},"
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
            "SS end-to-end is faster for this header with runtime input packing, "
            "direct APB streaming, and paired-word readback overhead included.",
            flush=True,
        )


def run_one_header(*, repo: Path, header: Path, index: int, total: int, work_root: Path,
                   uart_capture: Path, uart_dev: str, uart_baud: int, header_timeout: int,
                   openocd_cfg: Path, elf_wait_ms: int, cc: str, arch: str, opt: str,
                   openocd_retries: int, openocd_timeout: int, repetitions: int, warmups: int,
                   execution_attempt: int,
                   compile_only: bool, soc_clk_hz: int, summary_csv: Path) -> PerfResult | None:
    token = sanitize_token(header.stem)
    work_dir = work_root / f"{index:02d}_{token}"
    work_dir.mkdir(parents=True, exist_ok=True)

    source_path = work_dir / f"{token}.c"
    elf_path = work_dir / f"{token}.elf"
    attempt_tag = f"run{execution_attempt}"
    uart_log = work_dir / f"{token}.{attempt_tag}.uart.log"
    openocd_log = work_dir / f"{token}.{attempt_tag}.openocd.log"
    nucleo_log = work_dir / f"{token}.{attempt_tag}.nucleo_reset.log"

    source_path.write_text(render_c_source(header, repetitions, warmups), encoding="utf-8")
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
    ], cwd=repo)
    try:
        time.sleep(0.25)
        reset_nucleo(nucleo_log)
        time.sleep(0.25)
        load_and_run_elf(
            openocd_cfg, elf_path, elf_wait_ms, openocd_log, openocd_retries, openocd_timeout
        )
        rc = capture.wait()
    except Exception:
        capture.kill()
        capture.wait()
        raise
    if rc != 0:
        raise RuntimeError(f"UART perf run failed rc={rc}; see {uart_log}")

    try:
        result = parse_uart_result(header, uart_log)
    except (KeyError, ValueError) as exc:
        raise RuntimeError(f"malformed PERF aggregate in {uart_log}: {exc}") from exc
    shutil.copyfile(uart_log, work_dir / f"{token}.uart.log")
    shutil.copyfile(openocd_log, work_dir / f"{token}.openocd.log")
    shutil.copyfile(nucleo_log, work_dir / f"{token}.nucleo_reset.log")
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
    parser.add_argument("--elf-wait-ms", type=int, default=10,
                        help="Delay after resume; warmup keeps measured runs after JTAG disconnect")
    parser.add_argument("--openocd-retries", type=int, default=3,
                        help="Retry an ELF load unless OpenOCD verifies every byte")
    parser.add_argument("--openocd-timeout", type=int, default=15,
                        help="Kill a stuck OpenOCD load attempt after this many seconds")
    parser.add_argument("--header-attempts", type=int, default=3,
                        help="Re-run a header when UART output is missing or malformed")
    parser.add_argument("--repetitions", type=int, default=7,
                        help="Odd number of measured CPU/SS pairs per valid header")
    parser.add_argument("--warmups", type=int, default=1,
                        help="Untimed CPU/SS pairs before measured repetitions")
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
    args.openocd_cfg = args.openocd_cfg.resolve()
    args.uart_capture = args.uart_capture.resolve()
    if args.repetitions < 3 or args.repetitions > 31 or args.repetitions % 2 == 0:
        print("ERROR: --repetitions must be an odd value from 3 through 31", file=sys.stderr)
        return 2
    if args.warmups < 0 or args.warmups > 8:
        print("ERROR: --warmups must be from 0 through 8", file=sys.stderr)
        return 2
    if args.openocd_retries < 1:
        print("ERROR: --openocd-retries must be at least 1", file=sys.stderr)
        return 2
    if args.openocd_timeout < 5:
        print("ERROR: --openocd-timeout must be at least 5 seconds", file=sys.stderr)
        return 2
    if args.header_attempts < 1 or args.header_attempts > 5:
        print("ERROR: --header-attempts must be from 1 through 5", file=sys.stderr)
        return 2
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
    headers = select_headers(args, repo)
    stamp = time.strftime("%Y-%m-%d_%H%M%S")
    work_root = (args.log_dir / stamp / "generated_perf").resolve()
    summary_csv = work_root.parent / "perf_summary.csv"

    print("GROUP2 CPU-vs-subsystem GEMM perf compare", flush=True)
    print(f"mode={args.mode} headers={len(headers)} log_dir={work_root.parent}", flush=True)
    print(f"soc_clk_hz={args.soc_clk_hz}", flush=True)
    print(
        f"repetitions={args.repetitions} warmups={args.warmups} "
        f"openocd_retries={args.openocd_retries} openocd_timeout={args.openocd_timeout}s "
        f"header_attempts={args.header_attempts}",
        flush=True,
    )
    if args.mode == "random":
        print(f"random_seed={args.seed}", flush=True)

    results: list[PerfResult] = []
    for idx, header in enumerate(headers, start=1):
        result = None
        for execution_attempt in range(1, args.header_attempts + 1):
            try:
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
                    openocd_retries=args.openocd_retries,
                    openocd_timeout=args.openocd_timeout,
                    repetitions=args.repetitions,
                    warmups=args.warmups,
                    execution_attempt=execution_attempt,
                    cc=args.cc,
                    arch=args.riscv_arch,
                    opt=args.opt,
                    compile_only=args.compile_only,
                    soc_clk_hz=args.soc_clk_hz,
                    summary_csv=summary_csv,
                )
                break
            except RuntimeError as exc:
                if args.compile_only or execution_attempt == args.header_attempts:
                    raise
                print(
                    f"PERF_HEADER_RETRY,{header.name},attempt={execution_attempt},reason={exc}",
                    flush=True,
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
        avg_cold_speedup = sum(
            (r.cpu_cold_cycles / r.ss_cold_cycles) for r in valid if r.ss_cold_cycles
        ) / max(1, sum(1 for r in valid if r.ss_cold_cycles))
        print(
            "PERF_FINAL,"
            f"headers={len(results)},"
            f"failed={len(failed)},"
            f"valid_headers={len(valid)},"
            f"avg_valid_speedup={avg_speedup:.3f},"
            f"avg_valid_cold_speedup={avg_cold_speedup:.3f},"
            f"summary_csv={summary_csv},"
            f"{'PASS' if not failed else 'FAIL'}",
            flush=True,
        )
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
