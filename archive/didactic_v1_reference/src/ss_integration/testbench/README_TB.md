# SA Subsystem Testbench Guide

This directory contains the verification assets for the integrated SA
subsystem under `src/ss_integration`.

The tests are written from a firmware-visible point of view. They drive the
subsystem through APB registers and APB data windows instead of directly
forcing internal RTL signals. This is intentional: the goal is to verify the
same control and data flow that FPGA firmware will eventually use.

## 1. What Is Tested

The testbench suite checks three levels of behavior.

| Level | File | Purpose |
| --- | --- | --- |
| SystemVerilog smoke test | `tb_subsystem_weight_stationary.sv` | Quick XSIM sanity check for the APB sequence, weight reuse, output valid, and output release behavior. |
| Directed cocotb regression | `cocotb/test_subsystem_gemm_cocotb.py` | APB-level functional tests with real GEMM header slices, randomized tile sequences, error cases, and optional full mode5 GEMM. |
| Full all-header cocotb regression | `cocotb/test_all_gemm_headers_full_cocotb.py` | Runs every selected `sw/gemm/include/array_mode*.h` header as a complete firmware-style GEMM against the RTL tile engine. |

The common verification target is `subsystem_topmodule`.

## 2. Directory Layout

| Path | Description |
| --- | --- |
| `README.md` | This unified testbench guide. |
| `tb_subsystem_weight_stationary.sv` | SystemVerilog APB smoke test. |
| `run_weight_stationary_xsim.ps1` | Vivado XSIM wrapper for the SystemVerilog smoke test. |
| `cocotb/requirements.txt` | Python package requirements for cocotb execution. |
| `cocotb/run_subsystem_gemm_cocotb.py` | Python runner for the directed cocotb regression. |
| `cocotb/run_subsystem_gemm_cocotb.ps1` | PowerShell wrapper for the directed cocotb regression. |
| `cocotb/run_subsystem_gemm_cocotb.sh` | Linux/WSL wrapper for the directed cocotb regression. |
| `cocotb/test_subsystem_gemm_cocotb.py` | Directed APB-level cocotb tests. |
| `cocotb/run_all_gemm_headers_full_cocotb.ps1` | PowerShell wrapper for the full all-header regression. |
| `cocotb/run_all_gemm_headers_full_cocotb.sh` | Linux/WSL wrapper for the full all-header regression. |
| `cocotb/test_all_gemm_headers_full_cocotb.py` | Full GEMM regression for all selected headers. |

Generated logs are written under the repository-level `build/` directory.

| Build Directory | Main Logs |
| --- | --- |
| `build/ss_integration_cocotb/` | `subsystem_gemm_cocotb_build.log`, `subsystem_gemm_cocotb.log`, `subsystem_gemm_cocotb.xml` |
| `build/ss_integration_all_headers_cocotb/` | `all_headers_full_gemm_build.log`, `all_headers_full_gemm.log`, `all_headers_full_gemm.xml` |

## 3. Prerequisites

For the cocotb tests:

- Python 3
- `cocotb`
- Verilator or Icarus Verilog

The shell wrappers check for cocotb and install the packages from
`cocotb/requirements.txt` if needed.

On Windows, the PowerShell wrappers use WSL by default because a native Windows
Icarus package may compile the RTL but fail to load the 64-bit cocotb VPI
library. Use `-UseNative` only when your native simulator and Python setup are
known to work together.

For the SystemVerilog XSIM smoke test:

- Vivado tools must be available from `PATH`
- `xvlog`, `xelab`, and `xsim` must be callable from PowerShell

## 4. Common Firmware-Visible Execution Model

All cocotb tests use the same APB sequence that firmware is expected to use.

1. Reset the subsystem.
2. Write `CONFIG` with activation precision, weight precision, `tile_m`,
   `tile_n`, `tile_k`, and `batch_count`.
3. Pulse `CONTROL.load_weights`.
4. Stream the packed weight tile through the APB weight window.
5. Stream one activation batch through the APB activation window.
6. Poll `STATUS.output_valid`.
7. Read the APB output window.
8. Pulse `CONTROL.release_output`.
9. Repeat activation batches while the same weight tile remains stationary.
10. Load a new weight tile only when moving to a new output-column/K tile.

The tests do not assume that the RTL autonomously walks a full GEMM. The RTL is
a tile engine. The firmware or cocotb testbench is responsible for the outer
loops over `M`, `N`, and `K`.

## 5. Matrix Convention

The testbenches follow the same layout as `sw/gemm/gemm.c`.

```text
A[i,k] is row-major M x K
W[n,k] is row-major N x K
C[i,n] = sum_k A[i,k] * W[n,k]
```

The RTL returns raw 64-bit accumulator values for one output tile. Bias
addition, final `C_TYPE` casting, and accumulation across multiple K tiles are
handled by the firmware model in cocotb.

This means the direct hardware comparison is usually:

```text
raw_tile[m,n] == sum_{k in current tile_k} A[m,k] * W[n,k]
```

The full-GEMM comparisons then do:

```text
raw_accum[m,n] = sum over all K tiles of raw_tile[m,n]
final[m,n]     = cast_C_TYPE(raw_accum[m,n] + bias[n])
golden[m,n]    = header golden array entry
```

## 6. Quick Start

Run the directed cocotb regression from the repository root:

```powershell
.\src\ss_integration\testbench\cocotb\run_subsystem_gemm_cocotb.ps1
```

Linux/WSL equivalent:

```bash
./src/ss_integration/testbench/cocotb/run_subsystem_gemm_cocotb.sh
```

Run the full all-header regression:

```powershell
.\src\ss_integration\testbench\cocotb\run_all_gemm_headers_full_cocotb.ps1 -SummaryValues 8
```

Run only one header through the all-header regression:

```powershell
.\src\ss_integration\testbench\cocotb\run_all_gemm_headers_full_cocotb.ps1 `
  -HeaderGlob array_mode5_8b_32b_32_32_32_random.h `
  -SummaryValues 16
```

Run the XSIM smoke test:

```powershell
.\src\ss_integration\testbench\run_weight_stationary_xsim.ps1
```

Expected final line for the XSIM smoke test:

```text
WEIGHT_STATIONARY_TB_RESULT,pass
```

Successful cocotb runs end with:

```text
FINAL_RESULT: PASS
```

If a directed check fails, a simulator error occurs, or an all-header run hits
an out-of-range header data issue, the final line is `FINAL_RESULT: FAIL`.

## 7. SystemVerilog Smoke Test

`tb_subsystem_weight_stationary.sv` is a compact APB-only testbench. It checks
the most important control-flow behavior without Python infrastructure.

The sequence is:

1. Write `CONFIG`.
2. Pulse `CONTROL.load_weights`.
3. Stream one INT4 weight tile.
4. Stream three activation batches without reloading weights.
5. Wait for `STATUS.output_valid`.
6. Copy the compact output window into a scratch buffer.
7. Pulse `CONTROL.release_output`.
8. Verify that the copied output remains correct after the hardware buffer is
   released.

This test proves that:

- one loaded weight tile is reused across multiple activation batches,
- output readback is blocking until firmware releases the output,
- `weights_valid` remains high until the final batch is released,
- the basic APB-visible status and control sequence is coherent.

Use this test as a quick compile-and-smoke check. Use the cocotb tests for
broader data coverage.

## 8. Directed cocotb Regression

The directed regression is implemented in:

```text
cocotb/test_subsystem_gemm_cocotb.py
```

The recommended wrapper is:

```powershell
.\src\ss_integration\testbench\cocotb\run_subsystem_gemm_cocotb.ps1
```

### 8.1 Wrapper Options

| PowerShell Option | Default | Meaning |
| --- | --- | --- |
| `-Sim` | `verilator` | cocotb simulator name. |
| `-Header` | empty | Specific `sw/gemm/include` header for randomized sequence sampling. |
| `-RandomHeaders` | `2` | Number of randomly selected headers when `-Header` is not provided. |
| `-RandomCases` | `2` | Number of randomized tile sequences per selected header. |
| `-RandomSeed` | `20260521` | Seed for deterministic random sequence generation. |
| `-FullMode5` | disabled | Enables the full mode5 32x32x32 GEMM test. |
| `-FullGemmSummaryValues` | `64` | Number of full-GEMM golden/RTL samples printed in the summary. |
| `-UseNative` | disabled | Run on native Windows instead of WSL. |

Equivalent environment variables for Linux/WSL:

| Environment Variable | Meaning |
| --- | --- |
| `SIM` | Simulator name, usually `verilator` or `icarus`. |
| `GEMM_HEADER` | Specific header basename to sample. |
| `GEMM_RANDOM_SEED` | Random seed. |
| `GEMM_RANDOM_HEADERS` | Number of random headers. |
| `GEMM_RANDOM_CASES` | Number of random sequences per header. |
| `GEMM_RANDOM_MAX_TILE_M` | Maximum randomized `tile_m`. |
| `GEMM_RANDOM_MAX_TILE_N` | Maximum randomized `tile_n`. |
| `GEMM_RANDOM_MAX_TILE_K` | Maximum randomized `tile_k`. |
| `GEMM_RANDOM_MAX_BATCHES` | Maximum randomized batch count. |
| `RUN_FULL_GEMM_MODE5` | Set to `1` to enable the full mode5 test. |
| `FULL_GEMM_SUMMARY_VALUES` | Number of full-GEMM value samples in the terminal summary. |

### 8.2 Directed Test Scenarios

| Scenario | What It Proves |
| --- | --- |
| `test_mode6_header_weight_stationary_three_batches` | Uses a real INT8 activation x INT4 weight header slice and verifies that one stationary weight tile is reused across three activation batches. |
| `test_mode8_header_two_weight_tiles_firmware_accumulation` | Uses a real INT16 activation x INT4 weight header and checks two separate K tiles, proving that firmware can accumulate multiple raw RTL partial sums into one final result. |
| `test_reload_weights_between_transactions_changes_result` | Loads one weight tile, computes a result, then loads a different weight tile and proves the old weights are not accidentally reused. |
| `test_mixed_precision_small_sweep_and_short_k` | Exercises representative mixed precision combinations and short `tile_k` cases without running a full 32x32 GEMM. |
| `test_randomized_sequences_from_gemm_headers` | Samples random legal tile shapes from one or more real GEMM headers and automatically computes the expected output for each sampled sequence. |
| `test_mode5_full_gemm_8b_x_32b_32x32_firmware_tiling` | Optional full 32x32x32 mode5 test using INT8 activations, INT32 weights, firmware-style K accumulation, bias add, and int32 cast. |
| `test_invalid_sequence_protection` | Verifies that illegal firmware ordering, such as activation writes before a valid weight context, raises sticky error state instead of corrupting datapath state. |
| `test_output_blocking_policy_rejects_next_batch_until_release` | Verifies the blocking output policy: firmware must read and release the current output before sending the next activation batch. |

### 8.3 Randomized Header Sampling

The randomized test is data-driven. A team member can choose a header without
editing Python code:

```powershell
.\src\ss_integration\testbench\cocotb\run_subsystem_gemm_cocotb.ps1 `
  -Header array_mode9_16b_8b_32_32_32_random.h `
  -RandomSeed 1234 `
  -RandomCases 4
```

If `-Header` is omitted, the test selects `-RandomHeaders` headers from
`sw/gemm/include`.

Expected values are computed automatically from the selected header arrays.
The testbench parses:

- `M_d`, `K_d`, `N_d`
- `input_unpacked`
- `weights_unpacked`
- precision information encoded in the header filename

Then it randomly chooses legal tile ranges, streams those ranges into the RTL,
and computes the golden raw output using the same GEMM equation:

```text
expected[m,n] = sum_k activation[m,k] * weight[n,k]
```

So randomized testing is not a fixed hard-coded answer table. The expected
result follows the selected header and selected random tile coordinates.

### 8.4 Optional Full mode5 GEMM

The full mode5 test is disabled by default because it is heavier than the
directed slice tests. Enable it with:

```powershell
.\src\ss_integration\testbench\cocotb\run_subsystem_gemm_cocotb.ps1 `
  -FullMode5 `
  -RandomHeaders 1 `
  -RandomCases 1 `
  -FullGemmSummaryValues 32
```

This runs:

```text
array_mode5_8b_32b_32_32_32_random.h
```

The test executes the complete 32x32x32 GEMM as firmware would:

1. Sweep output-column tiles in `N`.
2. Sweep K tiles.
3. Load one INT32 weight tile.
4. Reuse that weight tile across the M-row activation batches.
5. Read raw 64-bit output tiles.
6. Accumulate raw partial sums in Python.
7. Add header bias.
8. Cast the result to int32.
9. Compare all 1024 final matrix elements against the header `golden` array.

## 9. Full All-Header GEMM Regression

The all-header regression is implemented in:

```text
cocotb/test_all_gemm_headers_full_cocotb.py
```

This is the broadest correctness test currently available. It runs every
selected GEMM header as a complete matrix multiplication through the
APB-visible RTL tile engine.

Default command:

```powershell
.\src\ss_integration\testbench\cocotb\run_all_gemm_headers_full_cocotb.ps1
```

Run only a subset:

```powershell
.\src\ss_integration\testbench\cocotb\run_all_gemm_headers_full_cocotb.ps1 `
  -HeaderGlob array_mode5_*.h `
  -SummaryValues 8
```

Linux/WSL equivalent:

```bash
ALL_HEADERS_GLOB='array_mode*.h' \
ALL_HEADERS_SUMMARY_VALUES=8 \
SIM=verilator \
./src/ss_integration/testbench/cocotb/run_all_gemm_headers_full_cocotb.sh
```

### 9.1 All-Header Wrapper Options

| PowerShell Option | Default | Meaning |
| --- | --- | --- |
| `-Sim` | `verilator` | cocotb simulator name. |
| `-HeaderGlob` | `array_mode*.h` | Glob under `sw/gemm/include` selecting headers to run. |
| `-SummaryValues` | `8` | Number of golden/RTL samples printed per header. |
| `-PrintAllValues` | disabled | Print every checked value instead of only samples. |
| `-UseNative` | disabled | Run on native Windows instead of WSL. |

Equivalent environment variables:

| Environment Variable | Meaning |
| --- | --- |
| `ALL_HEADERS_GLOB` | Header glob under `sw/gemm/include`. |
| `ALL_HEADERS_SUMMARY_VALUES` | Number of samples printed per header. |
| `ALL_HEADERS_PRINT_ALL_VALUES` | Set to `1` to print every checked value. |
| `ALL_HEADERS_REALTIME` | Set to `0` to disable live per-header progress. |
| `SIM` | Simulator name. |

### 9.2 All-Header Test Algorithm

For each selected header, the testbench:

1. Parses `M_d`, `K_d`, `N_d`, input arrays, weight arrays, bias, and golden
   output.
2. Infers activation and weight precision from the header filename.
3. Checks whether the input and weight values fit the declared signed
   precision range.
4. Sweeps output-column tiles in `N`.
5. Sweeps K tiles.
6. Loads one weight tile.
7. Reuses that weight tile across all M-row batches.
8. Reads each raw 64-bit output tile.
9. Accumulates the K partial sums in Python.
10. Adds bias and casts to the header output width.
11. Compares every final output element against the header `golden` array.

This directly tests the intended firmware/RTL contract: the subsystem performs
tile-level raw MAC work, while firmware owns the GEMM outer loops and final
post-processing.

### 9.3 Live Progress Output

Long all-header runs print one live line as each header completes:

```text
[LIVE 01] array_mode0_4b_4b_32_32_32_random.h: PASS | matched=1024/1024 mismatches=0 | cycles=...
```

The final live line summarizes the whole regression:

```text
LIVE FINAL: headers=... matched=... mismatches=... cycles=... failed=... PASS
```

After simulation exits, the runner prints a more detailed human-readable
summary with:

- header configuration,
- signed input/weight range checks,
- cycle counts,
- APB traffic,
- performance metrics,
- golden/RTL sample values,
- per-header PASS/FAIL,
- final PASS/FAIL.

### 9.4 Known Header Data-Range Caveat

The RTL treats INT4 values as signed 4-bit numbers, so the legal INT4 range is:

```text
-8 to 7
```

If a header declares INT4 weights but contains values outside that range, the
hardware-visible value is the sign-extended 4-bit interpretation, not the
larger C literal. For example, decimal `8` in INT4 becomes `-8` after 4-bit
sign extension.

The all-header test reports signed range checks per header:

```text
Ranges  : act=... ok=..., weight=... ok=...
```

If a header such as `array_mode6_8b_4b_32_32_32_row-index.h` fails because its
declared INT4 weight data exceeds `-8..7`, treat that as a header data-range
issue unless the intended project policy changes to saturate, clamp, or reject
out-of-range firmware data before it reaches the RTL.

## 10. Output Format

The cocotb tests emit both machine-readable log lines and human-readable
terminal summaries.

Directed regression log tags:

| Tag | Meaning |
| --- | --- |
| `COCOTB_SCENARIO` | Configuration of one test scenario. |
| `COCOTB_CHECK` | One expected/actual comparison. |
| `COCOTB_CASE` | Final result for one directed scenario. |
| `COCOTB_FULL_GEMM_RESULT` | Full mode5 GEMM aggregate result. |

All-header regression log tags:

| Tag | Meaning |
| --- | --- |
| `COCOTB_ALL_HEADER_BEGIN` | Start of one header run. |
| `COCOTB_ALL_HEADER_TXN` | Metrics for one weight-stationary tile transaction. |
| `COCOTB_ALL_HEADER_CHECK` | One final golden/RTL output comparison. |
| `COCOTB_ALL_HEADER_SUMMARY` | Per-header correctness and metric summary. |
| `COCOTB_ALL_HEADERS_FINAL` | Aggregate result across all selected headers. |

The last terminal line is always:

```text
FINAL_RESULT: PASS
```

or:

```text
FINAL_RESULT: FAIL
```

## 11. Performance Metrics

The all-header regression reports performance metrics without adding RTL
performance counters. The cocotb monitor counts APB transactions and samples
visible top-level activity signals.

These numbers are end-to-end APB-level metrics. They include:

- `CONFIG` writes,
- `CONTROL` writes,
- weight writes,
- activation writes,
- status polling,
- output buffer readback,
- APB wait-state cycles,
- output release commands,
- SA settle/drain cycles.

So they measure firmware-visible system throughput, not pure PE datapath peak.

### 11.1 Peak Array Throughput

The physical array is 8 x 8:

```text
ARRAY_PEAK_MACS_PER_CYCLE = 8 * 8 = 64
```

This is the theoretical peak if all 64 PEs perform useful MAC work every cycle.

### 11.2 useful_mac_ops

For one full GEMM header:

```text
useful_mac_ops = M * N * K
```

For the provided 32x32x32 headers:

```text
useful_mac_ops = 32 * 32 * 32 = 32768
```

For one tile transaction:

```text
useful_mac_ops = tile_m * batch_count * tile_n * tile_k
```

Example with `tile_m=8`, `batch_count=4`, `tile_n=8`, and `tile_k=8`:

```text
useful_mac_ops = 8 * 4 * 8 * 8 = 2048
```

### 11.3 effective_mac_per_cycle

```text
effective_mac_per_cycle = useful_mac_ops / cycles
```

This is the most direct end-to-end throughput metric. It includes APB traffic
and output readback, so it will be much lower than the 64 MAC/cycle PE peak.

### 11.4 system_pe_utilization_pct

```text
system_pe_utilization_pct =
    100 * useful_mac_ops / (64 * cycles)
```

This estimates how much of the theoretical 8x8 PE peak is used across the
entire APB-visible execution time.

Low values are expected because the current subsystem has no DMA. Firmware
must write inputs through APB, poll status, and read outputs through APB.

### 11.5 sa_active_utilization_pct

```text
sa_active_utilization_pct =
    100 * useful_mac_ops / (64 * sa_en_cycles)
```

This looks only at cycles where `sa_en` is active. It is closer to datapath
activity than system-level utilization, but it is still approximate because
`sa_en` can include weight settle, systolic wavefront movement, and drain/write
back cycles.

### 11.6 cycles_per_mac

```text
cycles_per_mac = cycles / useful_mac_ops
```

Lower is better. This is useful when comparing architectural changes that
affect APB traffic or output buffer policy.

### 11.7 cycles_per_output

```text
cycles_per_output = cycles / (M * N)
```

For 32x32 GEMM, there are 1024 final output elements.

### 11.8 APB Traffic Metrics

The all-header test reports:

```text
apb_writes
apb_reads
apb_access_cycles
apb_write_cycles
apb_read_cycles
apb_wait_cycles
config_writes
control_writes
weight_writes
activation_writes
status_reads
status_read_cycles
output_reads
output_read_cycles
```

These metrics help identify whether a change improves the datapath or only
moves the bottleneck to APB traffic.

Current output data is 64-bit per element, read through a 32-bit APB bus. One
8x8 output tile therefore requires:

```text
8 * 8 * 2 = 128 APB reads
```

This is why output readback dominates many full-GEMM runs.

### 11.9 Phase and Activity Metrics

The all-header test also reports:

```text
sa_en_cycles
input_vector_cycles
load_settle_cycles
output_drain_cycles
out_write_cycles
output_valid_cycles
phase_idle_cycles
phase_load_cycles
phase_batch_cycles
phase_drain_cycles
phase_error_cycles
visible_signals
```

Use these to localize stalls:

- high `phase_load_cycles` usually points to weight load cost,
- high `phase_batch_cycles` usually points to activation stream cost,
- high `phase_drain_cycles` or `output_read_cycles` points to output handling,
- high `phase_idle_cycles` usually points to firmware sequencing overhead.

### 11.10 weight_reuse_factor

```text
weight_reuse_factor = output_tiles / transactions
```

In the normal 32x32x32 full-header flow, one `N x K` weight tile is reused
across four M-row batches:

```text
weight_reuse_factor = 64 output tiles / 16 transactions = 4
```

If this value moves toward 1, the implementation is not exploiting the
weight-stationary dataflow effectively.

## 12. How to Interpret PASS/FAIL

A PASS means:

- the APB control sequence completed,
- the expected status behavior occurred,
- the RTL raw outputs matched the Python reference model,
- full-GEMM final outputs matched the header golden array after firmware-style
  accumulation, bias add, and cast.

A FAIL can come from different causes:

- RTL datapath mismatch,
- wrong APB sequence handling,
- output not released before the next batch,
- sticky error behavior not matching expectation,
- header values outside their declared signed precision range,
- simulator build/runtime failure.

Always inspect the relevant log under `build/` after a failure. The summary
prints representative mismatches, but the log contains the full machine-readable
record.

## 13. Troubleshooting


### Native Windows simulator issue

If the native run fails with a cocotb VPI or Python library loading error, use
the default WSL path:

```powershell
.\src\ss_integration\testbench\cocotb\run_subsystem_gemm_cocotb.ps1
```

Only use:

```powershell
-UseNative
```

when the native simulator/Python/cocotb stack is confirmed to work.

### Verilator warnings

The runners pass `-Wno-fatal` for Verilator. Warnings still appear in the build
log, but style or width warnings do not stop functional regression.

### Performance signal visibility

The all-header runner passes `--public-flat-rw` to Verilator so cocotb can
sample internal top-level activity signals for metric reporting. This is only
for simulation and does not add RTL performance counters.

## 14. Suggested Team Workflow

Use this order before pushing RTL changes:

1. Run the XSIM smoke test if Vivado is available.
2. Run the directed cocotb regression.
3. Run one full header such as mode5:

```powershell
.\src\ss_integration\testbench\cocotb\run_all_gemm_headers_full_cocotb.ps1 `
  -HeaderGlob array_mode5_8b_32b_32_32_32_random.h `
  -SummaryValues 16
```

4. Run the complete all-header regression before merging:

```powershell
.\src\ss_integration\testbench\cocotb\run_all_gemm_headers_full_cocotb.ps1 `
  -HeaderGlob array_mode*.h `
  -SummaryValues 8
```

5. Compare both correctness and metrics against the previous run.

For architecture changes, the most useful comparison fields are:

```text
effective_mac_per_cycle
system_pe_utilization_pct
sa_active_utilization_pct
cycles_per_mac
cycles_per_output
apb_writes
apb_reads
apb_wait_cycles
output_read_cycles
phase_load_cycles
phase_batch_cycles
phase_drain_cycles
weight_reuse_factor
```
