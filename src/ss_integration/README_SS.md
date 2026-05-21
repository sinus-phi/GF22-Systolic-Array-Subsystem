# SA Integration RTL

This directory is the active integration workspace for the student SA
subsystem. All active HDL in this path uses the `subsystem_` prefix.

## Files

| File | Role |
|---|---|
| `subsystem_topmodule.sv` | APB-facing top that connects control, input frontend, SA datapath, and output buffer. |
| `subsystem_pkg.sv` | Register map, phase encoding, CONFIG decode, and word-count helpers. |
| `subsystem_apb_if.sv` | APB timing adapter with backend-ready wait-state support. |
| `subsystem_addr_decoder.sv` | Local register/input/output address policy and APB fault classification. |
| `subsystem_regbank.sv` | CONFIG storage, CONTROL command pulses, STATUS/ERROR/IRQ readback. |
| `subsystem_sa_ctrl.sv` | Single-authority 5-state FSM plus counter-based output drain/write scheduling. |
| `subsystem_input_frontend.sv` | Reduced frontend: sign-extend packed APB words and emit SA vectors. |
| `subsystem_sa.sv` | Indrayudh systolic array, renamed only for integration namespace hygiene. |
| `subsystem_pe.sv` | Signed PE with 64-bit saturating MAC and overflow sideband. |
| `subsystem_output_buffer.sv` | Row-wide output buffer with parametric row-stride decode and synchronous read response. |

## Current Data Path

```text
APB write windows
  0x100 weight words
  0x200 activation words
        |
        v
subsystem_input_frontend
        |
        v
subsystem_sa -> subsystem_pe array
        |
        v
subsystem_output_buffer
        |
        v
APB output read window 0x400-0x7ff
```

`subsystem_sa_ctrl` is the only system-level controller. The input frontend
does not own transaction state; it only reacts to valid weight/activation words
allowed by `subsystem_sa_ctrl` and the address decoder. Output latency,
drain advancement, and output-buffer write pulses are also generated inside
`subsystem_sa_ctrl` with counters rather than a second FSM.

Packed INT4/INT8/INT16 input elements are sign-extended to 32 bits before
entering the PE datapath. Accumulator results are 64-bit values exposed as two
32-bit APB words per output element.

The PE saturates signed 64-bit accumulator overflow instead of wrapping. A
sticky overflow flag is exposed in `STATUS[14]` so firmware can detect that one
or more results were clamped.

Firmware must send full 8-element vectors to the frontend. When `K < 8`, the
unused lanes should be padded in the APB input stream.

Output reads are modeled as synchronous memory accesses. The APB adapter holds
`PREADY` low until the output buffer returns a valid read response, so firmware
and testbench code must obey APB wait states instead of assuming single-cycle
output reads.

The output buffer is single-buffered. While `STATUS.output_valid` is high,
firmware owns the buffer and the controller blocks the next activation batch.
Drivers should therefore use a copy-release-first policy: copy the compact
output window into a CPU scratch buffer, immediately pulse `release_output`, and
perform accumulation, bias, casting, logging, or reference checks on the copied
data after the hardware is allowed to start the next batch.

Rejected APB accesses assert `PSLVERR` and set sticky `STATUS.error`, but they
do not automatically abort the active transaction. The address decoder suppresses
all target pulses for rejected accesses, so firmware may clear the sticky fault
and continue when the current output/weight context is still valid.

Error handling is hierarchical. Recoverable APB faults are reported with
`STATUS.error` and `ERROR_CODE`; arithmetic overflow is reported separately with
`STATUS.overflow` because the PE saturates and continues; `PH_ERROR` is reserved
for fatal controller invariant failures such as an active transaction whose
CONFIG has become internally invalid. Fatal controller faults drop the current
weight/output context and require firmware to clear/reset before starting a new
transaction.

The output buffer write address is decoded from the configured row byte stride
instead of a fixed `wr_addr[8:6]` slice. This keeps the storage mapping tied to
`ARRAY_HEIGHT`, `ARRAY_WIDTH`, and `ACC_WIDTH` rather than the current 8x8
64-bit accumulator instance.
