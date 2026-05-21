# SA Subsystem GEMM Execution Guide

This document describes the current RTL in `src/ss_integration`. It is intended
as the detailed handoff guide for understanding, modifying, or integrating the subsystem.

The short `README.md` in this directory remains a file-structure overview. This
document focuses on architecture, control/data flow, module hierarchy, and the
step-by-step behavior of each RTL block. The verification code is kept under
`testbench/`; it is mentioned here only as the regression entry point, not
documented in detail.

## 1. Current Scope

The current subsystem is an APB-controlled 8x8 systolic-array tile engine. It is
not a fully autonomous GEMM engine that walks a complete matrix by itself.

One hardware transaction handles a bounded tile:

| Parameter | Meaning | Current Range |
|---|---|---:|
| `tile_m` | Number of activation/output rows in one batch | 1..8 |
| `tile_n` | Number of output columns / weight vectors | 1..8 |
| `tile_k` | Reduction lanes used in one tile | 1..8 |
| `batch_count` | Number of activation batches using the same loaded weight tile | 1..32 |

Firmware is responsible for decomposing a larger GEMM, for example a 32x32x32
problem, into 8x8x8 hardware transactions. When the full K dimension is larger
than 8, each hardware output is a partial sum for one K tile. Firmware must read
those partial results, accumulate them in software, add bias, and cast/store the
final C matrix value.

### 1.1 Why Tiling Is Required

GEMM computes:

```text
C[M x N] = A[M x K] * W[N x K]^T
```

Equivalently, each output element is a dot product:

```text
C[m][n] = sum over k ( A[m][k] * W[n][k] )
```

The provided GEMM headers currently use 32x32x32 shapes:

```text
M = 32 output rows / activation rows
N = 32 output columns / weight vectors
K = 32 reduction length per dot product
```

The hardware array, however, is physically only 8x8:

```text
physical SA rows    = 8
physical SA columns = 8
```

That means the hardware cannot compute the whole 32x32 output matrix in one
transaction. It can only cover up to:

```text
8 output rows  x  8 output columns
```

at a time. It also consumes at most 8 K-lanes per hardware transaction. The full
K length is 32, so one final output tile needs four K slices:

```text
K = 32 -> 4 slices of tile_k = 8
```

This is the reason for tiling. Tiling simply means cutting one large matrix
operation into smaller pieces that fit into the physical hardware.

### 1.2 Mapping GEMM Axes to the 8x8 Array

The tile parameters map to GEMM axes as follows:

| GEMM Axis | Hardware Tile Field | Hardware Meaning |
|---|---|---|
| M axis | `tile_m` | Number of activation rows processed in one batch |
| N axis | `tile_n` | Number of output columns / weight vectors loaded into SA columns |
| K axis | `tile_k` | Number of dot-product lanes processed in one partial sum |

For the common 8x8x8 tile:

```text
tile_m = 8
tile_n = 8
tile_k = 8
```

The hardware computes one partial output tile:

```text
partial_C[8 rows x 8 columns] for one 8-lane K slice
```

Because full K is 32, firmware must run four K slices and accumulate them:

```text
C_tile_final = partial_K0 + partial_K1 + partial_K2 + partial_K3
```

Only after all K slices are accumulated should firmware add bias and cast to the
header's final C type.

### 1.3 Concrete 32x32x32 Example

A 32x32 output matrix contains:

```text
32 rows / 8 rows per tile = 4 M tiles
32 cols / 8 cols per tile = 4 N tiles
32 K    / 8 K per tile    = 4 K tiles
```

So a complete 32x32x32 GEMM can be viewed as:

```text
4 N-column tiles
  x 4 K-reduction tiles
  x 4 M-row batches
= 64 hardware output tiles
```

The current full-header cocotb test uses weight-stationary scheduling:

```text
for each N tile:
  for each K tile:
    load one 8x8 weight tile
    reuse that weight tile for four M-row activation batches
```

That is why `batch_count=4` is useful for a 32x32x32 problem. One loaded weight
tile is reused across the four M-direction batches:

```text
batch 0 -> output rows  0..7
batch 1 -> output rows  8..15
batch 2 -> output rows 16..23
batch 3 -> output rows 24..31
```

The weight tile is then replaced when firmware moves to the next N/K tile.

### 1.4 What Each Tile Actually Contains

For one `tile_m=8`, `tile_n=8`, `tile_k=8` transaction:

```text
Activation tile:
  A[m0:m0+7][k0:k0+7]
  -> 8 activation rows
  -> each row has 8 K elements

Weight tile:
  W[n0:n0+7][k0:k0+7]
  -> 8 output-column weight vectors
  -> each vector has 8 K elements

Output tile:
  partial_C[m0:m0+7][n0:n0+7]
  -> 8 x 8 partial sums
  -> each output is accumulated over only k0:k0+7
```

The key point is that a hardware output tile is not necessarily the final GEMM
result. It is final only if the whole K dimension fits in `tile_k`. For the
provided 32x32x32 headers, `tile_k=8` covers only one quarter of K, so the RTL
returns partial sums and firmware completes the final accumulation.

### 1.5 Why the Current RTL Stops at Tile Level

The current design deliberately keeps full-matrix traversal in firmware. This
keeps the RTL small and predictable:

- no hardware loop counters for full M/N/K traversal,
- no DMA,
- no internal large matrix address generator,
- no internal full-output accumulator memory,
- no hardware bias-add or final C-type cast.

The tradeoff is that firmware must schedule all tile loops, APB streams, output
reads, partial-sum accumulation, bias add, and final store.

## 2. Top-Level Architecture

The active top module is `subsystem_topmodule`.

```text
APB bus
  |
  v
subsystem_apb_if
  |
  v
subsystem_addr_decoder ----> subsystem_regbank
  |                               |
  |                               v
  |                         subsystem_sa_ctrl
  |                               |
  v                               v
subsystem_input_frontend ---> subsystem_sa ---> subsystem_output_buffer
                                  |                  |
                                  v                  v
                              subsystem_pe       APB output reads
```

The design intentionally has one system-level control authority:
`subsystem_sa_ctrl`.

Other blocks do not own long-running transaction state:

- `subsystem_apb_if` adapts APB timing to local pulses.
- `subsystem_addr_decoder` gates legal access by address and FSM phase.
- `subsystem_regbank` stores CONFIG, emits one-cycle CONTROL command pulses,
  and exposes STATUS/ERROR/IRQ.
- `subsystem_input_frontend` unpacks APB words into signed 32-bit SA vectors.
- `subsystem_sa` and `subsystem_pe` implement the datapath.
- `subsystem_output_buffer` stores row-wide SA results and exposes compact APB
  readback.

## 3. Firmware-Visible Address Map

The subsystem uses a 4 KiB local APB address space. The SoC interconnect selects
the subsystem; the RTL consumes `PADDR[11:0]`.

| Address Range | Access | Meaning |
|---|---|---|
| `0x000-0x0FF` | read/write | Register region |
| `0x100-0x1FF` | write | Weight stream window |
| `0x200-0x2FF` | write | Activation stream window |
| `0x400-0x7FF` | read | Output read window |

The weight and activation windows are stream windows, not random-access
memories. Repeated writes to the same address are valid because every accepted
APB write is consumed in arrival order.

### Register Map

| Offset | Name | Access | Meaning |
|---:|---|---|---|
| `0x000` | `CONTROL` | write command / read zero | Starts or clears actions |
| `0x004` | `STATUS` | read | Phase, sticky flags, output word count |
| `0x008` | `CONFIG` | read/write in IDLE | Precision, tile sizes, batch count |
| `0x00C` | `PROGRESS` | read zero | Reserved for future debug builds |
| `0x010` | `ERROR_CODE` | read | Last sticky error code |
| `0x014` | `OUTPUT_WORDS` | read | Number of valid 32-bit output words |

Only the offsets listed above are implemented. Reads from other register
offsets and writes to registers other than `CONTROL` and `CONFIG` are rejected
with `PSLVERR` and `ERR_BAD_ADDR`.

The generated Student subsystem wrapper does not expose `PSTRB` to this compact
integration top. All accesses are therefore treated as 32-bit word accesses:
firmware should use full-word APB loads/stores, and unaligned local addresses
are rejected with `ERR_UNALIGNED`.

### CONTROL Bits

`CONTROL` is command-only. Bits are not stored; an accepted write creates
one-cycle pulses.

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `load_weights` | Start a new weight-load transaction |
| 1 | `release_output` | Release current output buffer ownership |
| 2 | `clear_done` | Clear `done_sticky` |
| 3 | `clear_error` | Clear recoverable sticky error/overflow status |
| 4 | `soft_reset` | Clear CONFIG and controller context |

### STATUS Bits

| Bits | Name | Meaning |
|---:|---|---|
| `[0]` | `busy` | FSM is in `LOAD_WEIGHTS`, `BATCH_COMPUTE`, or `DRAIN_WRITEBACK` |
| `[1]` | `error_sticky` | Recoverable or fatal error has been latched |
| `[2]` | `done_sticky` | At least one output tile completed |
| `[3]` | `weights_valid` | A logical weight context is active |
| `[4]` | `output_valid` | Firmware owns a valid output tile |
| `[5]` | `output_full` | Mirrors current output-valid ownership |
| `[6]` | `output_blocked` | A non-final batch is stalled because firmware has not released the current output |
| `[9:7]` | `phase` | FSM phase encoding |
| `[13:10]` | `error_code[3:0]` | Compact copy of current error code |
| `[14]` | `overflow_sticky` | At least one PE saturated an accumulator |
| `[15]` | reserved | Reads as zero |
| `[23:16]` | `output_words` | Valid output word count when `output_valid=1` |
| `[31:24]` | reserved | Reads as zero |

`busy=0` only means the FSM phase is not one of the active stream/drain phases.
It does not by itself mean that firmware can start a new transaction. On the
final batch, `phase` may return to `IDLE` while `output_valid=1` and
`weights_valid=1` remain asserted until firmware pulses `release_output`.
Firmware must check/release `output_valid` before changing `CONFIG` or starting
another `load_weights`.

### CONFIG Bits

| Bits | Field | Meaning |
|---:|---|---|
| `[1:0]` | activation precision | `00=INT4`, `01=INT8`, `10=INT16`, `11=INT32` |
| `[3:2]` | weight precision | `00=INT4`, `01=INT8`, `10=INT16`, `11=INT32` |
| `[8:4]` | `tile_m` | Rows in one activation/output batch, 1..8 |
| `[13:9]` | `tile_n` | Output columns / weight vectors, 1..8 |
| `[18:14]` | `tile_k` | Reduction lanes, 1..8 |
| `[24:19]` | `batch_count` | Activation batches per loaded weight tile, 1..32 |
| `[31:25]` | reserved | Must be zero |

`CONFIG` is accepted only in `IDLE` and only when no logical weight context is
active. This keeps precision and tile dimensions stable during a transaction.

## 4. Precision and Packing

All PE operands are normalized to signed 32-bit values before they enter the SA.
The input frontend sign-extends packed APB words according to the configured
stream precision.

| Precision | Elements per 32-bit APB Word |
|---|---:|
| INT4 | 8 |
| INT8 | 4 |
| INT16 | 2 |
| INT32 | 1 |

The number of APB words per K vector is:

```text
words_per_vector = ceil(tile_k / elems_per_word(precision))
```

The transaction stream lengths are:

```text
weight_words_per_transaction = tile_n * ceil(tile_k / elems_per_word(weight_precision))
activation_words_per_batch   = tile_m * ceil(tile_k / elems_per_word(activation_precision))
output_words_per_batch       = tile_m * tile_n * 2
```

The `* 2` in `output_words_per_batch` comes from the 64-bit accumulator width:
each accumulator is read as two 32-bit APB words.

Important firmware packing rule:

If `tile_k` does not use every packed element in the final APB word, the unused
high elements are ignored. Firmware must start the next weight vector or
activation row at a new APB word. It must not pack the next logical vector into
the unused high bits of the previous word.

## 5. Transaction Flow

A normal tile transaction follows this sequence:

```text
1. Write CONFIG in IDLE.
2. Write CONTROL.load_weights.
3. Wait until STATUS.phase == LOAD_WEIGHTS.
4. Stream weight words to 0x100.
5. Wait until STATUS.phase == BATCH_COMPUTE and STATUS.weights_valid == 1.
6. Stream one activation batch to 0x200.
7. Wait until STATUS.output_valid == 1.
8. Copy the compact output window from 0x400 into a CPU scratch buffer.
9. Write CONTROL.release_output, usually with CONTROL.clear_done.
10. If batch_count remains, stream the next activation batch as soon as
    PH_BATCH_COMPUTE returns.
11. Accumulate, bias, cast, log, or compare the copied output while hardware is
    allowed to work on the next batch.
12. If no batch remains, the visible phase can return to IDLE, but the final
    output and logical weight context remain owned until release_output clears
    output_valid and weights_valid.
```

### FSM Phases

| Phase | Encoding | Main Responsibility |
|---|---:|---|
| `PH_IDLE` | 0 | Accept a new valid CONFIG/load command |
| `PH_LOAD_WEIGHTS` | 1 | Accept packed weight stream and settle load wavefront |
| `PH_BATCH_COMPUTE` | 2 | Accept activation stream for one batch |
| `PH_DRAIN_WRITEBACK` | 3 | Advance remaining partial sums and write output buffer |
| `PH_ERROR` | 4 | Hold after fatal controller invariant failure |

There is no separate `DONE` state. Completion is represented by
`done_sticky` and `output_valid`.

## 6. Weight-Stationary Behavior

Weights are loaded into PE-local `weight_reg` flops. Once the weight stream and
settle interval complete, `weights_valid` rises and the same weight tile can be
reused for multiple activation batches.

Logical weight lifetime:

```text
LOAD_WEIGHTS completes
  -> weights_valid = 1
  -> BATCH_COMPUTE / DRAIN_WRITEBACK repeat for batch_count batches
  -> final output_valid may coexist with PH_IDLE until firmware releases it
  -> final release_output
  -> weights_valid = 0
  -> phase is IDLE and CONFIG/load_weights are available again
```

The PE physical registers may still contain old bit values after the logical
context is dropped, but firmware must treat them as invalid. A new transaction
must start from `CONTROL.load_weights` and a fresh weight stream.

## 7. Weight Load Settle

The SA skews weight data and load pulses across columns. After the final weight
word is accepted, the controller keeps advancing the array long enough for the
last load wavefront to reach the rightmost columns.

Current equation:

```text
LOAD_SETTLE_CYCLES = ((ARRAY_WIDTH - 1) * MAC_STAGES) + 1
```

For the current 8x8 array and `MAC_STAGES=2`:

```text
LOAD_SETTLE_CYCLES = ((8 - 1) * 2) + 1 = 15 cycles
```

This is a settle interval, not a flush. It does not clear PE weights.

## 8. Output Drain and Readback

After the last activation word for one batch is accepted, the FSM enters
`PH_DRAIN_WRITEBACK`. The goal is to keep advancing the SA until the in-flight
partial-sum wavefront reaches the output rows and can be written into the
output buffer.

Current equation:

```text
OUTPUT_START_CYCLES = (ARRAY_HEIGHT + ARRAY_WIDTH - 1) * MAC_STAGES
```

For the current 8x8 array and `MAC_STAGES=2`:

```text
OUTPUT_START_CYCLES = (8 + 8 - 1) * 2 = 30 cycles
```

The output buffer stores one physical SA row per write:

```text
one write = ARRAY_WIDTH lanes * ACC_WIDTH bits
```

Firmware sees a compact stream:

```text
for m in 0 .. tile_m-1:
  for n in 0 .. tile_n-1:
    read accumulator[m][n].low32
    read accumulator[m][n].high32
```

Output reads are synchronous-memory friendly. `subsystem_topmodule` holds APB
`PREADY` low until `subsystem_output_buffer` returns `rd_valid_o`.

## 9. Error Handling Model

The subsystem separates recoverable firmware/API mistakes from fatal controller
invariants.

| Class | Examples | RTL Behavior | Firmware Response |
|---|---|---|---|
| Recoverable APB fault | Bad address, unaligned access, writing activation before weights, reading output before `output_valid` | `PSLVERR=1`, `error_sticky=1`, `ERROR_CODE` set; rejected target pulse is suppressed | Read error, fix sequence, write `clear_error`; transaction context may still be usable |
| Arithmetic overflow | Signed 64-bit accumulator overflow in PE | PE saturates, `overflow_sticky=1`, GEMM continues | Treat output as saturated; clear status after handling |
| Fatal controller fault | Internal controller invariant broken, such as active transaction with invalid CONFIG | FSM enters `PH_ERROR`, logical context is dropped | Clear/reset and restart transaction |

Error codes:

| Code | Name | Meaning |
|---:|---|---|
| 0 | `ERR_NONE` | No error |
| 1 | `ERR_BAD_ADDR` | Undefined local address |
| 2 | `ERR_UNALIGNED` | Non-word-aligned APB access |
| 3 | `ERR_BAD_STATE` | Access not legal in current FSM phase |
| 4 | `ERR_OUTPUT_RANGE` | Output read index is beyond `OUTPUT_WORDS` |
| 5 | `ERR_INVALID_CONFIG` | `load_weights` attempted with invalid CONFIG |
| 6 | `ERR_FATAL_CTRL` | Internal controller invariant failure |

## 10. Module-by-Module Operational Details

This section explains how each module behaves internally. It intentionally
starts each module with a compact port-reference table, then describes the
internal behavior step by step. The goal is to make both the interface and the
data/control policy easy to follow from firmware request to SA computation to
output readback.

### 10.1 `subsystem_topmodule`

`subsystem_topmodule` is the integration point. It does not contain a large
algorithm of its own; its main job is to connect the APB-facing control plane,
the single control FSM, the input stream frontend, the SA datapath, and the
output buffer.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `PADDR` | input | 32 | APB byte address from SoC interconnect |
| `PENABLE` | input | 1 | APB access-phase qualifier |
| `PSEL` | input | 1 | APB slave select |
| `PWDATA` | input | 32 | APB write data |
| `PWRITE` | input | 1 | APB write/read direction |
| `PRDATA` | output | 32 | APB read data |
| `PREADY` | output | 1 | APB transfer completion / wait-state control |
| `PSLVERR` | output | 1 | APB error response |
| `clk_i` | input | 1 | Subsystem clock |
| `rst_ni` | input | 1 | Active-low reset |
| `irq_en_i` | input | 1 | SoC-level interrupt enable |
| `ss_ctrl_i` | input | 8 | Currently unused sideband from wrapper |
| `pmod_gpi` | input | 16 | PMOD input sideband, currently unused |
| `irq_o` | output | 1 | Interrupt output |
| `pmod_gpo` | output | 16 | PMOD output, tied off in compact version |
| `pmod_gpio_oe` | output | 16 | PMOD output enable, tied off in compact version |

Step-by-step behavior:

1. The top module receives raw APB signals from the Student_SS wrapper.
2. `subsystem_apb_if` converts those APB phases into one local read or write
   pulse.
3. `subsystem_addr_decoder` decides which local target should receive that
   pulse: register bank, weight stream, activation stream, or output buffer.
4. `subsystem_regbank` stores CONFIG and converts accepted CONTROL writes into
   command pulses.
5. `subsystem_sa_ctrl` consumes those command pulses and owns the visible
   subsystem phase.
6. `subsystem_input_frontend` consumes accepted weight or activation APB words
   and emits full 8-lane signed vectors.
7. The top module decides when the SA advances:

```text
sa_en = input_vector_valid | load_settle_active | output_drain_active
```

This means the array moves in exactly three cases:

- a real weight or activation vector is entering,
- the weight-load wavefront is still settling through the skewed SA path,
- the output partial-sum wavefront is being drained into the output buffer.

8. During a real input vector, the top module forwards both `vector_data` and
   `sa_load`. During settle or drain cycles, it drives input data and load to
   zero while still allowing the internal wavefront to advance.
9. SA output lanes are written into `subsystem_output_buffer` only when
   `subsystem_sa_ctrl` asserts `out_wr_en`.
10. For output reads, the top module treats the output buffer as synchronous
    memory. It holds APB `PREADY` low until the output buffer asserts
    `rd_valid`.

Important policy:

- Control ownership stays centralized in `subsystem_sa_ctrl`.
- The top module does not add a second transaction FSM.
- The top module only combines local handshakes and routes data.

### 10.2 `subsystem_apb_if`

`subsystem_apb_if` hides APB timing from the rest of the subsystem. Downstream
modules do not need to know about setup phase, access phase, or wait states.
They only see one-cycle local pulses.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `PADDR` | input | 32 | Raw APB address |
| `PENABLE` | input | 1 | APB access phase |
| `PSEL` | input | 1 | APB select |
| `PWDATA` | input | 32 | Raw APB write data |
| `PWRITE` | input | 1 | APB write/read direction |
| `PRDATA` | output | 32 | APB read data response |
| `PREADY` | output | 1 | APB ready response |
| `PSLVERR` | output | 1 | APB error response |
| `clk_i` | input | 1 | Clock |
| `rst_ni` | input | 1 | Active-low reset |
| `local_addr_o` | output | 12 | Latched local 4 KiB address |
| `bus_wdata_o` | output | 32 | Latched local write data |
| `bus_wena_o` | output | 1 | One-cycle local write pulse |
| `bus_rena_o` | output | 1 | One-cycle local read pulse |
| `bus_rdata_i` | input | 32 | Local read data from selected backend |
| `bus_ready_i` | input | 1 | Backend response ready |
| `bus_err_i` | input | 1 | Backend reports this accepted access as error |

Step-by-step behavior for one APB access:

1. Firmware starts an APB transfer.
2. APB enters the access phase when both `PSEL` and `PENABLE` are high.
3. The adapter detects the first access-phase cycle as `request_start`.
4. On `request_start`, it latches:

```text
local_addr_q = PADDR[11:0]
bus_wdata_q  = PWDATA
bus_wena_q   = PWRITE
bus_rena_q   = !PWRITE
```

5. It sets an internal pending bit.
6. The one-cycle local pulse goes to the decoder and selected backend.
7. The APB transfer remains pending until `bus_ready_i` is high.
8. When `bus_ready_i=1`, APB `PREADY` is asserted.
9. If the selected backend reported `bus_err_i=1`, APB `PSLVERR` is asserted in
   the same completion cycle.
10. After completion, the pending bit drops and the adapter can accept the next
    APB request.

Why this matters:

- Register reads can complete quickly.
- Output reads can take extra cycles because the output buffer behaves like a
  synchronous memory.
- The APB protocol remains correct even if future BRAM/SRAM wrappers add more
  read latency.

### 10.3 `subsystem_addr_decoder`

`subsystem_addr_decoder` is both an address decoder and a policy gate. It
protects the datapath from illegal firmware ordering.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `local_addr_i` | input | 12 | Local APB address |
| `bus_wdata_i` | input | 32 | Write data, used mainly for CONTROL validation |
| `bus_wena_i` | input | 1 | Local write access pulse |
| `bus_rena_i` | input | 1 | Local read access pulse |
| `phase_i` | input | 3 | Current controller phase |
| `config_valid_i` | input | 1 | Current CONFIG passes validation |
| `weights_valid_i` | input | 1 | Logical weight context is active |
| `output_valid_i` | input | 1 | Output buffer is owned by firmware |
| `output_words_i` | input | 32 | Number of readable compact output words |
| `reg_wena_o` | output | 1 | Accepted register write |
| `reg_rena_o` | output | 1 | Accepted register read |
| `weight_wena_o` | output | 1 | Accepted weight stream write |
| `act_wena_o` | output | 1 | Accepted activation stream write |
| `out_rena_o` | output | 1 | Accepted output-buffer read |
| `out_word_idx_o` | output | 8 | Compact output word index |
| `dec_err_o` | output | 1 | Access was rejected |
| `dec_error_code_o` | output | 32 | Error code for rejected access |

The decoder first classifies the local address:

```text
0x000-0x0FF -> register region
0x100-0x1FF -> weight stream
0x200-0x2FF -> activation stream
0x400-0x7FF -> output read window
```

Then it applies access rules.

For every access:

1. Check whether the address is 32-bit aligned.
2. If unaligned, reject it with `ERR_UNALIGNED`.
3. If aligned, classify the region.
4. If the region and current FSM phase are compatible, assert exactly one target
   pulse.
5. If the access is not allowed, assert `dec_err` and suppress every target
   pulse.

Weight write policy:

1. A write to the weight window is legal only in `PH_LOAD_WEIGHTS`.
2. If legal, the decoder emits `weight_wena`.
3. If not legal, the decoder emits `ERR_BAD_STATE`.

Activation write policy:

1. A write to the activation window is legal only in `PH_BATCH_COMPUTE`.
2. `weights_valid` must also be high.
3. If both conditions are true, the decoder emits `act_wena`.
4. Otherwise it emits `ERR_BAD_STATE`.

CONTROL write policy:

1. `load_weights` may start only from `PH_IDLE`.
2. `load_weights` is rejected if an old output is still valid.
3. `load_weights` is rejected if CONFIG is invalid.
4. Other command bits, such as release and clear, are passed to the register
   bank when the register address is legal.

CONFIG write policy:

1. CONFIG can be changed only in `PH_IDLE`.
2. No logical weight context may be active.
3. This prevents firmware from changing precision or tile sizes while the SA
   still holds a valid weight tile.

Output read policy:

1. Output reads are legal only when `output_valid=1`.
2. The compact output word index must be below `output_words`.
3. Out-of-range reads return `ERR_OUTPUT_RANGE`.
4. Reads before output ownership is given to firmware return `ERR_BAD_STATE`.

Important design choice:

Rejected accesses do not generate weight, activation, output, or register
target pulses. Therefore a bad APB access can be reported without directly
modifying datapath state. This is why most firmware mistakes are recoverable.

### 10.4 `subsystem_regbank`

`subsystem_regbank` is intentionally small. It stores only the firmware-visible
state needed by the compact integration version. It does not schedule
transactions and does not count stream words.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `clk_i` | input | 1 | Clock |
| `rst_ni` | input | 1 | Active-low reset |
| `local_addr_i` | input | 12 | Register address |
| `bus_wdata_i` | input | 32 | Register write data |
| `reg_wena_i` | input | 1 | Accepted register write pulse |
| `reg_rena_i` | input | 1 | Accepted register read pulse |
| `phase_i` | input | 3 | Current controller phase |
| `weights_valid_i` | input | 1 | Weight context status |
| `done_sticky_i` | input | 1 | Done sticky flag from controller |
| `error_sticky_i` | input | 1 | Error sticky flag from controller |
| `overflow_sticky_i` | input | 1 | Saturation sticky flag from controller |
| `output_valid_i` | input | 1 | Output tile is ready for firmware |
| `output_full_i` | input | 1 | Output buffer valid/full indication |
| `output_blocked_i` | input | 1 | Controller is waiting for release |
| `output_words_i` | input | 32 | Valid compact output word count |
| `error_code_i` | input | 32 | Current full error code |
| `irq_en_i` | input | 1 | IRQ enable from wrapper |
| `pmod_gpi` | input | 16 | PMOD input sideband |
| `config_o` | output | 32 | Stored CONFIG word |
| `config_valid_o` | output | 1 | CONFIG validity |
| `load_weights_cmd_o` | output | 1 | CONTROL bit 0 command pulse |
| `release_output_cmd_o` | output | 1 | CONTROL bit 1 command pulse |
| `clear_done_cmd_o` | output | 1 | CONTROL bit 2 command pulse |
| `clear_error_cmd_o` | output | 1 | CONTROL bit 3 command pulse |
| `soft_reset_cmd_o` | output | 1 | CONTROL bit 4 command pulse |
| `reg_rdata_o` | output | 32 | Register readback data |
| `irq_o` | output | 1 | Interrupt output |
| `pmod_gpo` | output | 16 | PMOD output, currently zero |
| `pmod_gpio_oe` | output | 16 | PMOD output enable, currently zero |

CONFIG handling:

1. On reset, CONFIG is zero.
2. On `soft_reset`, CONFIG is cleared.
3. On an accepted write to `OFF_CONFIG`, CONFIG is replaced with APB write data.
4. `config_valid` is computed combinationally from the stored CONFIG using
   package helper logic.

CONTROL handling:

1. CONTROL is not stored.
2. An accepted CONTROL write is decoded into one-cycle command pulses.
3. Multiple bits can be written together when useful.
4. For example, firmware often writes:

```text
CONTROL.release_output | CONTROL.clear_done
```

5. Because commands are pulses, reading `CONTROL` returns zero.

STATUS handling:

1. STATUS is built combinationally from controller state.
2. `busy` is derived from the current phase.
3. `output_words` is visible only when `output_valid=1`.
4. `overflow_sticky` is independent from `ERROR_CODE`.
5. The compact error code copy in STATUS mirrors only the low bits of
   `ERROR_CODE`; the full error value is available at `OFF_ERROR_CODE`.

IRQ handling:

1. There is no local IRQ mask register in this compact version.
2. The SoC-level `irq_en_i` directly gates the interrupt.
3. IRQ rises when either `done_sticky` or `error_sticky` is set.

PMOD handling:

1. PMOD input is currently unused.
2. PMOD outputs and output enables are tied to zero.
3. The ports remain present so the subsystem can keep the wrapper contract
   stable while PMOD functionality is deferred.

### 10.5 `subsystem_sa_ctrl`

`subsystem_sa_ctrl` is the single system-level FSM. It owns the transaction
phase, sticky status, stream counters, batch reuse, weight-load settle, and
output drain scheduling.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `clk_i` | input | 1 | Clock |
| `rst_ni` | input | 1 | Active-low reset |
| `load_weights_cmd_i` | input | 1 | Start a weight-load transaction |
| `release_output_cmd_i` | input | 1 | Firmware releases current output |
| `clear_done_cmd_i` | input | 1 | Clear done sticky |
| `clear_error_cmd_i` | input | 1 | Clear error/overflow sticky state |
| `soft_reset_cmd_i` | input | 1 | Reset controller context |
| `dec_err_i` | input | 1 | Decoder rejected an APB access |
| `dec_error_code_i` | input | 32 | Decoder error code |
| `weight_wena_i` | input | 1 | Accepted weight APB word |
| `act_wena_i` | input | 1 | Accepted activation APB word |
| `input_vector_valid_i` | input | 1 | Frontend emitted one SA vector |
| `mac_overflow_i` | input | 1 | Any SA output lane overflowed/saturated |
| `config_i` | input | 32 | Current CONFIG |
| `config_valid_i` | input | 1 | Current CONFIG validity |
| `weight_start_o` | output | 1 | Reset/start frontend weight stream |
| `activation_start_o` | output | 1 | Reset/start frontend activation stream |
| `load_settle_active_o` | output | 1 | Advance SA for weight-load settle |
| `output_drain_active_o` | output | 1 | Advance SA for output drain |
| `out_wr_en_o` | output | 1 | Write one output row |
| `out_wr_addr_o` | output | `BUFF_ADDR_WIDTH` | Row write address for output buffer |
| `phase_o` | output | 3 | Current FSM phase |
| `weights_valid_o` | output | 1 | Logical weight context is valid |
| `done_sticky_o` | output | 1 | Output completion sticky |
| `error_sticky_o` | output | 1 | Error sticky |
| `overflow_sticky_o` | output | 1 | Saturation sticky |
| `output_valid_o` | output | 1 | Output buffer is ready for firmware |
| `output_full_o` | output | 1 | Mirrors output-valid ownership |
| `output_blocked_o` | output | 1 | Waiting for firmware release |
| `output_words_o` | output | 32 | Valid compact output word count |
| `error_code_o` | output | 32 | Current error code |

Reset or soft reset behavior:

1. Phase returns to `PH_IDLE`.
2. Sticky done, error, and overflow flags are cleared.
3. Weight validity is cleared.
4. Output validity is cleared.
5. Stream counters and output scheduling counters are reset.

Starting a transaction:

1. Firmware writes CONFIG through the regbank.
2. Firmware writes `CONTROL.load_weights`.
3. The decoder allows this only if CONFIG is valid and phase is `PH_IDLE`.
4. The controller moves to `PH_LOAD_WEIGHTS`.
5. It loads `batch_remaining` from `cfg_batch_count`.
6. It clears previous sticky status.
7. It pulses `weight_start` so the input frontend resets its weight stream
   index.

Weight phase:

1. Every accepted weight APB word increments `weight_count`.
2. The target count is:

```text
weight_target = tile_n * ceil(tile_k / elems_per_word(weight_precision))
```

3. When `weight_count` reaches the target, the controller marks the weight
   stream as done.
4. It does not immediately enter compute.
5. It starts the weight-load settle counter.
6. While settle is active, it asserts `load_settle_active`, which causes the top
   module to advance the SA with zero input and zero load.
7. Once settle completes, the controller moves to `PH_BATCH_COMPUTE`.
8. `weights_valid` becomes high.
9. It pulses `activation_start` so the frontend starts a clean activation
   vector boundary.

Batch compute phase:

1. Every accepted activation APB word increments `act_count`.
2. The target count for one batch is:

```text
act_target = tile_m * ceil(tile_k / elems_per_word(activation_precision))
```

3. Once the batch input stream is complete, the controller moves to
   `PH_DRAIN_WRITEBACK`.
4. It does not clear weights; the same PE weights remain logically active.

Output drain scheduling:

1. The controller starts an output advance counter when activation computation
   begins.
2. The SA advances during real input vectors and drain cycles.
3. The first valid output row is expected after:

```text
OUTPUT_START_CYCLES = (ARRAY_HEIGHT + ARRAY_WIDTH - 1) * MAC_STAGES
```

4. After that point, the controller writes one output row whenever the output
   wavefront advances and a row remains.
5. The write address is:

```text
row_index * (ACC_WIDTH * ARRAY_WIDTH / 8)
```

6. When `tile_m` rows have been written, output generation for that batch is
   complete.

Output ownership and batch reuse:

1. When a batch output is complete, `output_valid` rises.
2. `done_sticky` is set.
3. `batch_remaining` decrements.
4. While `output_valid=1`, firmware owns the output buffer.
5. The controller does not accept the next activation batch until firmware
   releases the output.
6. If `batch_remaining > 0`, `release_output` moves the FSM back to
   `PH_BATCH_COMPUTE` and pulses `activation_start`.
7. If `batch_remaining == 0`, the FSM may already report `PH_IDLE`, but
   `output_valid` and `weights_valid` remain asserted until `release_output`.
8. The final `release_output` clears `output_valid` and `weights_valid`, making
   CONFIG updates and a new `load_weights` legal again.

Recoverable error handling:

1. Decoder faults set `error_sticky`.
2. The first outstanding error code is retained until firmware clears it.
3. The active phase is not automatically aborted.
4. This works because the decoder has already suppressed the illegal target
   pulse.

Fatal error handling:

1. Fatal errors are reserved for internal controller invariant failures.
2. Examples include an active transaction with invalid CONFIG or a zero target
   count.
3. In this case, the controller enters `PH_ERROR` and drops the current logical
   context.
4. Firmware must clear/reset and restart the transaction.

### 10.6 `subsystem_input_frontend`

`subsystem_input_frontend` converts packed APB words into the fixed 8-lane
signed vector format expected by the SA. It has no global transaction FSM.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `clk_i` | input | 1 | Clock |
| `rst_ni` | input | 1 | Active-low reset |
| `clear_i` | input | 1 | Clear frontend local state |
| `weight_start_i` | input | 1 | Start/reset weight vector stream |
| `activation_start_i` | input | 1 | Start/reset activation batch stream |
| `phase_i` | input | 3 | Current controller phase |
| `weight_precision_i` | input | 2 | Weight stream precision |
| `activation_precision_i` | input | 2 | Activation stream precision |
| `tile_k_i` | input | 32 | Number of meaningful K lanes |
| `word_i` | input | 32 | Accepted APB stream word |
| `weight_word_valid_i` | input | 1 | Current word belongs to weight stream |
| `activation_word_valid_i` | input | 1 | Current word belongs to activation stream |
| `vector_valid_o` | output | 1 | One SA vector is ready |
| `vector_data_o` | output | `ARRAY_HEIGHT*DATA_WIDTH` | Sign-extended vector lanes |
| `sa_load_o` | output | `ARRAY_WIDTH` | One-hot load pulse for SA columns |

Stream boundary behavior:

1. `weight_start` clears the current fill count and resets the weight vector
   index to zero.
2. `activation_start` clears the current fill count for a new activation batch.
3. `clear` resets local frontend state.
4. These boundaries prevent leftover packed elements from one logical vector
   from leaking into the next vector.

Precision selection:

1. If the accepted word is a weight word, the frontend uses weight precision.
2. If the accepted word is an activation word, it uses activation precision.
3. The two streams can use different precision settings in the same
   transaction.

Unpacking behavior:

1. The frontend decodes up to 8 elements from the 32-bit APB word.
2. INT4 uses bit 3 of each nibble as the sign bit.
3. INT8 uses bit 7 of each byte as the sign bit.
4. INT16 uses bit 15 of each halfword as the sign bit.
5. INT32 uses the whole APB word.
6. Each decoded element is sign-extended to the PE `DATA_WIDTH`, currently
   32 bits.

Vector fill behavior:

1. The frontend stores decoded elements into a small vector buffer.
2. It tracks how many logical K lanes have been received.
3. The active logical vector length is `tile_k`, not always 8.
4. Once `tile_k` elements are available, it emits `vector_valid`.
5. Lanes below `tile_k` contain signed decoded data.
6. Lanes from `tile_k` to 7 are padded with zero.

Weight stream behavior:

1. During `PH_LOAD_WEIGHTS`, each completed vector corresponds to one output
   column's weight vector.
2. The frontend emits a one-hot `sa_load` bit for the current weight vector
   index.
3. The first vector targets column 0, the second column 1, and so on.
4. After emitting the load bit, the frontend increments the weight vector index.

Activation stream behavior:

1. During `PH_BATCH_COMPUTE`, each completed vector corresponds to one
   activation row.
2. The frontend emits `vector_valid`.
3. It keeps `sa_load` at zero so PEs compute with the existing stationary
   weights instead of capturing new weights.

Firmware-visible packing rule:

If `tile_k=3` and precision is INT4, one APB word physically contains 8
nibbles, but only the first 3 are consumed for the current vector. The remaining
5 nibbles are ignored. Firmware must start the next vector at a new APB word.

### 10.7 `subsystem_sa`

`subsystem_sa` is the 2D systolic-array wrapper. It preserves the original
movement style: weights are loaded with column skew, activations move
horizontally, and partial sums move vertically.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `clk` | input | 1 | Clock |
| `rst_n` | input | 1 | Active-low reset |
| `en` | input | 1 | Advance SA pipeline |
| `load` | input | `ARRAY_WIDTH` | Per-column weight-load request before skew |
| `i_data` | input | `ARRAY_HEIGHT*DATA_WIDTH` | Left-edge input vector |
| `o_data` | output | `ARRAY_WIDTH*ACC_WIDTH` | Deskewed output accumulator lanes |
| `o_overflow` | output | `ARRAY_WIDTH` | Deskewed overflow flags per lane |

Input skew behavior:

1. The top row consumes row 0 input immediately.
2. Lower rows receive delayed versions of their corresponding input lanes.
3. The delay increases by `MAC_STAGES` per row.
4. This creates the staggered activation wavefront required by the systolic
   schedule.

Load skew behavior:

1. Column 0 receives its load pulse immediately.
2. Column 1 receives a delayed load pulse.
3. Each later column receives an additional `MAC_STAGES` delay.
4. This aligns the load pulse with the weight data as it moves horizontally
   through the array.

PE grid behavior:

1. The top PE in each column starts with zero partial sum.
2. Each lower PE receives the partial sum from the PE above.
3. The leftmost PE in each row receives the externally skewed activation data.
4. Other PEs receive activation data forwarded from the previous PE in the row.
5. Load and overflow sidebands follow the same general direction as their
   associated data or partial sum.

Output deskew behavior:

1. Different output columns naturally emerge at different times.
2. The wrapper delays earlier columns so all output lanes correspond to the
   same wavefront.
3. The overflow sideband is deskewed with the data, so overflow flags remain
   aligned with their accumulator results.

What the SA does not do:

- It does not know APB addresses.
- It does not know tile sizes.
- It does not know phase encoding.
- It does not decide when output is valid.
- It only advances when `en=1`.

### 10.8 `subsystem_pe`

`subsystem_pe` is the signed MAC cell. Each PE owns one local stationary weight
register.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `clk` | input | 1 | Clock |
| `rst_n` | input | 1 | Active-low reset |
| `en` | input | 1 | Advance PE pipeline |
| `i_load` | input | 1 | Capture incoming data as local weight |
| `i_overflow` | input | 1 | Incoming vertical overflow sideband |
| `o_load` | output | 1 | Forwarded load sideband |
| `o_overflow` | output | 1 | Forwarded overflow sideband |
| `i_data` | input | `DATA_WIDTH` signed | Activation data or weight-load data |
| `o_data` | output | `DATA_WIDTH` signed | Forwarded horizontal data |
| `i_sum` | input | `ACC_WIDTH` signed | Incoming vertical partial sum |
| `o_sum` | output | `ACC_WIDTH` signed | Output vertical partial sum |

Reset behavior:

1. Output data, output sum, load pipeline, overflow pipeline, and weight
   register are cleared.
2. Pipeline registers are reset according to `MAC_STAGES`.

Weight-load cycle:

1. When `en=1` and `i_load=1`, the PE captures `i_data` into `weight_reg`.
2. It forwards load through the pipeline so PEs below the current PE can also
   capture the correct weight at the correct time.
3. It suppresses MAC overflow for that cycle because the PE is loading, not
   computing.

Compute cycle:

1. When `en=1` and `i_load=0`, the PE treats `i_data` as activation data.
2. It multiplies the signed activation by the signed local weight.
3. The product is computed as a native `DATA_WIDTH x DATA_WIDTH` multiply.
4. The product is then sign-extended or truncated to accumulator width.
5. The PE adds the product to the incoming vertical partial sum.
6. The result is forwarded downward as `o_sum`.
7. The activation data is forwarded horizontally as `o_data`.

Saturation policy:

1. The PE checks signed addition overflow.
2. Positive overflow clamps to signed `ACC_MAX`.
3. Negative overflow clamps to signed `ACC_MIN`.
4. The overflow sideband is set and propagated downward.
5. The GEMM continues. Overflow is reported later through
   `STATUS.overflow_sticky`.

Pipeline behavior:

1. If `MAC_STAGES=1`, multiply/add result is produced in a single registered
   stage.
2. If `MAC_STAGES>1`, load, data, product, sum, and overflow are pipelined so
   timing remains aligned with the surrounding systolic array.

Important implementation detail:

The PE intentionally does not sign-extend both operands to `ACC_WIDTH` before
multiplication. Doing so could infer a much wider multiplier. Instead, the
multiplier stays at `DATA_WIDTH x DATA_WIDTH`, and only the product is adapted
to accumulator width.

### 10.9 `subsystem_output_buffer`

`subsystem_output_buffer` stores SA outputs in a row-wide format and exposes a
compact APB read stream. It is written in a BRAM/SRAM-friendly style.

Port summary:

| Port | Direction | Width | Role |
|---|---|---:|---|
| `clk_i` | input | 1 | Clock |
| `rst_ni` | input | 1 | Active-low reset |
| `clear_i` | input | 1 | Clear registered read response |
| `wr_en_i` | input | 1 | Write one row-wide output entry |
| `wr_addr_i` | input | `BUFF_ADDR_WIDTH` | Byte-stride-like output row address |
| `wr_data_i` | input | `ARRAY_WIDTH*ACC_WIDTH` | Full physical output row |
| `rd_req_i` | input | 1 | Compact output read request |
| `tile_n_i` | input | 32 | Number of visible output columns |
| `rd_word_idx_i` | input | 8 | Compact output word index |
| `rd_data_o` | output | 32 | Registered output read data |
| `rd_valid_o` | output | 1 | Read response valid |

Write behavior:

1. The controller asserts `wr_en` when one output row should be stored.
2. The write data contains all physical output lanes for that row:

```text
ARRAY_WIDTH * ACC_WIDTH
```

3. The write address is a byte-stride-like row address generated by the
   controller.
4. The output buffer decodes this address into a row index by comparing against
   parameterized row bases.
5. This avoids hard-coded slices such as `wr_addr[8:6]`.
6. The selected row entry is replaced with the full row-wide data.

Read behavior:

1. Firmware reads the output window using a compact word index.
2. The compact stream contains only `tile_m * tile_n * 2` 32-bit words.
3. The buffer maps the compact word index into:

```text
row index
lane index
low/high 32-bit word inside the 64-bit accumulator
```

4. The mapping uses `tile_n` so unused physical lanes are skipped.
5. For a 64-bit accumulator, each visible element is returned as low 32 bits
   followed by high 32 bits.

Synchronous-memory policy:

1. A read request is registered.
2. Read data is returned on the following registered response.
3. `rd_valid` tells the top module that the APB read can complete.
4. The top module holds `PREADY` low until `rd_valid=1`.

Clear behavior:

1. `clear` resets the registered read response.
2. It does not bulk-clear the memory array.
3. This matches real SRAM/BRAM behavior, where clearing every entry is usually
   not free.
4. Firmware must rely on `output_valid` and `OUTPUT_WORDS`, not on cleared
   memory contents.

### 10.10 `subsystem_pkg`

`subsystem_pkg` is not a runtime block, but it is important because it prevents
the modules from disagreeing on firmware-visible constants.

It defines:

- array shape constants,
- APB register offsets,
- error codes,
- phase encodings,
- precision packing helpers,
- CONFIG field extractors,
- transaction word-count helpers,
- output word-count helpers,
- CONFIG validity rules.

The most important policy functions are:

```text
weight_words_for(cfg)
act_words_for(cfg)
output_words_for(cfg)
config_valid(cfg)
```

These functions are shared by the controller, decoder, and register map so that
the same CONFIG word is interpreted consistently across the subsystem.

## 11. Full GEMM Responsibility Split

The RTL handles:

- One tile transaction at a time.
- Mixed-precision APB unpack/sign-extension.
- 8x8 systolic-array MAC.
- PE-local stationary weights during `batch_count`.
- 64-bit signed saturating accumulation.
- Output tile buffering and APB readback.
- Sticky status, overflow, and recoverable access faults.

Firmware handles:

- Matrix-level M/N/K tiling.
- Choosing tile sizes and batch count.
- Packing weight and activation vectors into APB words.
- Looping over K tiles and accumulating partial outputs.
- Adding bias.
- Casting/storing final C values.
- Polling status and issuing output release.

For a 32x32x32 GEMM with 8x8x8 tiles, a typical firmware loop is:

```c
for (n0 = 0; n0 < N; n0 += 8) {
  for (k0 = 0; k0 < K; k0 += 8) {
    configure(tile_m=8, tile_n=8, tile_k=8, batch_count=4);
    load_weight_tile(W[n0:n0+8][k0:k0+8]);

    for (m0 = 0; m0 < M; m0 += 8) {
      stream_activation_tile(A[m0:m0+8][k0:k0+8]);
      wait_output_valid();
      copy_partial_output_tile_to_scratch();
      release_output();
      accumulate_scratch_in_software_while_next_batch_can_run();
    }
  }
}

add_bias_and_cast_to_C();
```

The exact loop order can be adjusted, but the current RTL assumes firmware
explicitly orchestrates all full-matrix traversal.

## 12. Verification Entry Points

The testbench files are under:

```text
src/ss_integration/testbench/
```

The current cocotb regression includes:

- directed tile-level protocol tests,
- randomized tile sequences from GEMM headers,
- full-header GEMM execution through the APB-visible subsystem,
- optional performance metrics such as cycle count, APB traffic,
  effective MAC/cycle, and utilization estimates.

See `src/ss_integration/testbench/README.md` for the testbench flow and
performance metric definitions.
