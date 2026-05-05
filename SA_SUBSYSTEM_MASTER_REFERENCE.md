# SA Subsystem Master Reference

This document is the reference document for the whole team to understand and implement the Systolic Array Subsystem using the same baseline.  
Whenever a team member implements or connects the APB interface, address decoder, register bank, Main Control FSM, row injection, Systolic Array Core, Output block, IRQ, or PMOD, they should check this document first.

This document is not intended to force the detailed internal circuit implementation.  
The core purpose of this document is the following three points.

1. Define the sequence in which firmware controls the accelerator.
2. Define which signals each block exchanges at the top level.
3. Define a common contract so that even if each team member implements their own module differently internally, the whole system behaves the same way when connected.

---

## 1. Purpose and Scope of Responsibility

### 1.1 What This Document Defines

This document defines the items that must match from the subsystem top-level perspective.

- How an access from the APB bus is routed to an internal register or data path
- How the firmware-visible register map is organized
- In what sequence the accelerator changes state and operates
- The policy of receiving weight and activation through the same `ROW_INJECT_DATA` window, while interpreting their meaning according to the current FSM phase
- The meaning of `valid`, `ready`, data, and status signals between blocks
- The top-level protocol for reading results from the Output block in 32-bit APB word units
- The top-level meaning of IRQ and PMOD debug signals

These items must be aligned across the whole team.  
Even if the owner of one block changes its internal implementation, the meaning of the input and output signals defined in this document must remain the same.

### 1.2 What This Document Does Not Define

The following items are the internal implementation responsibility of the corresponding block owner.

- Internal PE structure
- How to construct the MAC
- How to align row/column-direction timing inside the SA
- Row injection FIFO depth and internal storage method
- Internal storage method of the Output block
- Output result width and result format
- How to split the output result and expose it to firmware
- What numeric policy to apply when arithmetic overflow occurs during computation
- Whether to use internal SRAM, register file, or small buffer

The important point is that the top level should not need to know these internal implementation methods.  
The top level only decides "what data came in", "in which phase it is valid", "whether the next block is ready to receive", and "whether firmware can read the result."
### 1.3 Why Our Team Needs This Document

Each team member currently owns a different module.  
If each person implements only by looking at their own module, the following problems can occur.

- The order for loading weights and the order for loading activations can be interpreted differently.
- Firmware and RTL can understand differently which register may be written and when.
- The SA Core owner may not be ready to receive data while the APB side keeps pushing data.
- An APB read may finish immediately even though the Output block is not yet ready for readback.
- DONE, ERROR, and IRQ generation conditions can be implemented differently by different modules.

This document is written to reduce these mismatches.  
Module internals may be implemented freely, but the externally visible top-level behavior must be unified.

---

## 2. Basic Terms to Know First

This section summarizes the basic concepts needed before reading the rest of the document.

### 2.1 APB

APB is the bus interface used by the CPU to read and write peripheral registers.  
Our subsystem operates as an APB slave. In other words, when the CPU creates an APB transaction, our subsystem decodes the address and performs register write, register read, data injection, output read, and related operations.

In our design, APB access is simplified with the following restrictions.

- Only 32-bit aligned access is treated as normal.
- Only full-word access is treated as normal.
- Byte write policy is not used as an internal contract.
- An access to an invalid address or an access in an invalid state is handled through `PSLVERR` or a sticky error.

These restrictions exist to simplify the implementation.  
Firmware must always access registers and data windows in 32-bit units.

The reason for restricting APB access this way is not that APB itself is complicated, but that we want to reduce the scope we must verify in this project.  
For example, if byte writes are allowed, `INT4`, `INT8`, `INT16`, and `INT32` packing becomes entangled with the byte enable policy. Then we would also have to define how the internal row injection word should be updated when firmware writes only certain bytes.  
The current goal is to complete the control flow and data flow of the systolic array accelerator reliably, so it is clearest to treat every APB access as one complete 32-bit command or one complete 32-bit data unit.

The person responsible for the APB Slave I/F must correctly handle the setup/access phases of the APB protocol. In contrast, the RegBank, Decoder, and FSM owners should simplify the internal signals so that they do not need to know the detailed APB protocol timing directly.  
That is, APB is the external rule that connects the SoC and our subsystem, while the internal blocks should not deal with APB directly. They should operate based on simpler signals generated by the APB I/F, such as `bus_wena`, `bus_rena`, `local_addr`, and `bus_wdata`.

### 2.2 Register

A register is a 32-bit storage location that firmware reads or writes to control the accelerator or check its status.  
For example, writing `CONTROL.start` starts the computation, and reading `STATUS.busy` tells whether the accelerator is currently running.

A register can look like a simple variable, but in hardware the following meanings are important.

- Some bits hold values written by firmware.
- Some bits are automatically changed by hardware depending on state.
- Some bits are cleared when firmware writes 1.
- Some registers can be written only in specific FSM states.

Therefore, the register map is not just an address table. It is a control contract between firmware and hardware.

Registers are needed because firmware cannot directly control every signal inside the hardware.  
Firmware can only send commands to the accelerator from C code by writing values to memory-mapped addresses. Hardware stores those values in the RegBank, and internal blocks such as the FSM or Frontend read and use them when needed.

Registers also organize hardware status into a form that firmware can understand.  
For example, internally there are many counters, FSM states, Output block states, and IRQ pending states, but firmware cannot directly see every internal signal. This is why firmware-visible registers such as `STATUS`, `ERROR_CODE`, and count registers are needed.  
Without these registers, firmware would have difficulty distinguishing whether the accelerator is stuck, still computing, or has output ready.

### 2.3 Local Offset

The absolute base address of our subsystem has not yet been finalized.  
After the supervisor meeting, once the student subsystem slot assigned to us is decided, `SS_BASE` will be fixed.

Inside RTL, we do not directly compare absolute addresses.  
We always use the following rule.

```text
local_addr = PADDR[11:0]
```

That is, the internal decoder interprets addresses only within the 4 KiB local window.  
Firmware/HAL accesses the subsystem later by adding a local offset to the assigned `SS_BASE`.

For example, if the local offset of the `CONTROL` register is `0x000`, the firmware address has the following form.

```text
CONTROL address = SS_BASE + 0x000
```

The advantage of this method is that the RTL internal address structure does not need to change even if the subsystem slot changes.

Using local offsets is especially important because our team still does not know which student subsystem slot we will receive.  
If RTL directly compares absolute addresses, the RTL address decoder must be modified every time the slot changes. In that case, it becomes easy for the firmware HAL, RTL, and testbench to accidentally use different base addresses.  
In contrast, if RTL only looks at `PADDR[11:0]` and only firmware/HAL changes `SS_BASE`, the internal design can remain unchanged even if the subsystem slot decision comes late.

Therefore, when writing documentation, RTL, and testbenches, do not write "this register is at `0x01053000`". Instead, write "this register is at `SS_BASE + 0x000`". 
If we follow this principle, the internal memory map will not shift even if the supervisor assigns a different slot later.

### 2.4 FSM State

The FSM state indicates which stage the accelerator is currently in.  
Our top-level FSM uses the following six states.

| State | Meaning |
|---|---|
| `IDLE_CFG` | State that receives configuration and waits for start |
| `WEIGHT_MAP` | State that maps weights into the SA |
| `ACT_STREAM_COMPUTE` | State where activations are injected while computation proceeds |
| `DRAIN_WRITEBACK` | State that transfers remaining results inside the SA to the Output block |
| `DONE` | State where the tile computation is finished and firmware can read the result |
| `ERROR` | State where an invalid access or invalid control sequence occurred |

The FSM state is the basis for judging whether firmware access is legal.  
For example, in the `WEIGHT_MAP` state, pushing weights is normal, while pushing activations is not a normal sequence.

The biggest reason the FSM state is needed is that the same APB write can have a different meaning depending on the current stage.  
A 32-bit value written to `ROW_INJECT_DATA` is always the same write if we only look at the address. However, if the FSM is in `WEIGHT_MAP`, that value is a weight, and if the FSM is in `ACT_STREAM_COMPUTE`, that value is an activation.  
Therefore, the Address Decoder and RegBank cannot judge only from the address. They must also consider the current `phase`.

The FSM state also makes the sequence firmware must follow clear.  
If firmware reads `STATUS.phase`, it can know whether it should currently load weights, load activations, or wait for results.  
When team members implement their own modules, aligning behavior around the FSM state allows different modules to share the same execution stage.

### 2.5 valid/ready Handshake

The most important rule for transferring data between blocks is the `valid/ready` handshake.  
However, using handshake in this document does not mean "we should always build a structure that stalls."
Our baseline performance goal is a normal no-wait fast path. In other words, during a normal sequence, each internal stage should be sufficiently pipelined so that it can receive data every cycle whenever possible.  
That is, normal register read/write, normal `ROW_INJECT_DATA` write, and prepared output read should not cause APB wait.  
Internally, it is also ideal for the row injection frontend, FIFO/staging, scheduler, SA Core, and Output block to keep `ready=1` in normal cases.

Even so, the reason we keep the `valid/ready` contract in the document is to clearly define when data transfer actually occurs.

- The sender asserts `valid=1` when the data is valid.
- The receiver asserts `ready=1` when it is ready to receive.
- Actual data transfer occurs in the same clock cycle when `valid=1` and `ready=1`.

Therefore, `ready` is not a signal for lowering performance. It is a protection signal that prevents data loss in exceptional situations.  
For example, immediately after reset, during clear, when a FIFO is full, when the Output block is unavailable, or when an internal pipeline is busy, a block may temporarily be unable to receive data.  
In such cases, `ready=0` must be available so that data is not lost and the upstream block or APB Slave I/F can safely wait.

Any interface with `valid/ready` in this document must follow these principles.

- If only `valid` is 1 and `ready` is 0, the data has not yet been transferred.
- If only `ready` is 1 and `valid` is 0, there is no data to transfer.
- Transfer count, state transition, and data consumption occur only in cycles where `valid && ready` is true.
- In a no-wait implementation, keeping `ready` always 1 still satisfies the contract.
- However, asserting `ready=1` without actually accepting the data is forbidden.

The part beginners most often misunderstand is the idea that having `ready` automatically means a slow design.  
That is not true. In normal cases, `ready=1` can remain asserted continuously, allowing data to pass every cycle. In that case, even though handshake signals exist, no actual stall occurs.  
The reason `ready` is needed is not "to slow down the normal case", but "to prevent data from disappearing in exceptional cases."
For example, if firmware writes a value to `ROW_INJECT_DATA` and the APB side returns `PREADY=1`, firmware believes that the value has been delivered to hardware.  
But if the internal FIFO is full and we still return `PREADY=1`, then from the firmware perspective the write has completed, while internally there is nowhere to store the data and it may be lost.  
Therefore, an internal `ready=0` situation must be exposed externally through an APB wait state or an error policy.

### 2.6 Token

In this document, a token means one data unit transferred through the row injection path.  
For example, if firmware writes one 32-bit word to `ROW_INJECT_DATA`, that write internally becomes one row injection token.

A token must include at least the following information.

- Whether this token is a weight or an activation
- Which row it should enter
- What the original 32-bit APB write data was
- What the current precision setting is
- How many real elements are contained in this word

The term token describes the data unit, not the internal implementation method.  
In actual RTL, it can be represented as a struct, packed signal bundle, FIFO entry, or any other method.

The reason we must explicitly think in terms of tokens is that one APB write becomes more than a simple 32-bit number internally.  
The 32-bit number must carry along whether it is a weight or activation, which row it should go to, what the precision is, and how many elements it contains.  
If this information is not managed together, the Frontend, FIFO, and Scheduler can interpret the same data differently.

Therefore, even if the actual RTL does not define a struct named token, the group of information corresponding to a token must exist.  
For example, if `mode`, `row_idx`, `lane_valid`, and `lane_data` move together, that group serves the role of the row injection token described in this document.

### 2.7 Tile

The full matrix can be 32x32 or larger, but the hardware SA has a limited size it can process at once.  
The baseline is an 8x8 array, and tile dimensions are limited to at most 8.

The hardware register `DIM` does not mean the full matrix size. It means the size of the current tile that hardware will process.

- `tile_m`: number of output rows in the current tile
- `tile_n`: number of output columns in the current tile
- `tile_k`: dot product length

Firmware manages how to divide the full matrix into multiple tiles and in what order to send each tile to the accelerator.

The tile concept is needed because the hardware array size can be smaller than the full matrix size.  
The C code example provided by the school uses a 32x32 matrix, but our baseline SA is considered around 8x8. Therefore, the hardware does not process the entire 32x32 matrix at once. Instead, firmware must split it into smaller operations of 8x8 or less and run the accelerator multiple times.

Therefore, the `DIM` register is not a register that stores the "full problem size". 
`DIM` tells how many rows, columns, and K length one tile operation currently sent to the accelerator has.  
The loop order of the full matrix, the starting position of each tile, and placing multiple tile results into the final matrix remain the responsibility of firmware/HAL.

---

## 3. Overall System Behavior Model

This section explains the overall flow from data entering the system to results leaving the system.  
First it is described from the firmware perspective, and then from the hardware perspective.

### 3.1 Normal Execution Sequence from the Firmware Perspective

Firmware uses the accelerator in the following order.

0. In the SoC controller register block, enable the clock of the target student subsystem and release ICN/subsystem reset. If needed, also configure SoC-level interrupt enable and PMOD routing.
1. Set activation precision and weight precision in the `CONFIG` register.
2. Set the current tile size `tile_m`, `tile_n`, and `tile_k` in the `DIM` register.
3. If needed, configure accelerator-local `IRQ_ENABLE` and `SA_PMOD_CTRL`.
4. Write `CONTROL.start` to start the accelerator.
5. When the FSM enters `WEIGHT_MAP`, write weights sequentially to `ROW_INJECT_DATA`.
6. When weight mapping completes, the FSM moves to `ACT_STREAM_COMPUTE`.
7. Firmware writes activations sequentially to the same `ROW_INJECT_DATA` address.
8. As activations enter, the SA Core performs computation.
9. When all inputs have entered, the FSM moves to `DRAIN_WRITEBACK`.
10. Results from the SA Core are transferred to the Output block.
11. When all results are accepted by the Output block, the FSM moves to `DONE`.
12. Firmware checks `STATUS.done` or `STATUS.result_valid`, then directly reads the `OUTPUT_READ_WINDOW` at `0x400-0x4FF` in 32-bit word units.
13. To run the next tile, firmware uses `clear_done` or a new `start` sequence.

Step 0 is SoC platform initialization that must be performed before accessing accelerator-internal registers.  
According to the SoC Documentation, the controller block is located at `CTRL_BASE = 0x01040000`, and registers such as `ss_rst`, `ss_N_ctrl`, and `pmod_sel` manage subsystem reset, clock enable, interrupt forwarding, and PMOD routing. If the clock is not enabled or reset is not released at this stage, accelerator registers accessed later through `SS_BASE + local_offset` cannot be assumed to work normally.

The actions firmware/HAL must perform during platform initialization should be considered separately from accelerator-internal register configuration.

1. In `CTRL_BASE + ss_N_ctrl`, set the clock enable bit for the corresponding subsystem. Based on the Didactic-SoC repo, bit 0 is the standard clock enable and bit 1 is the fast clock enable. If our subsystem uses only the standard clock, bit 0 is sufficient. If the fast clock domain is also used, bit 1 must also be set. Since the high-speed clock helper in the repo is centered around the fast clock bit, the final HAL must clearly write the clock bit combination that is actually required.
2. Release reset for the corresponding subsystem and interconnect. Based on the student subsystem example and platform control flow in the Didactic-SoC repo, `reset_int` delivered to the subsystem is treated with an active-low convention. That is, `reset_int=0` means reset asserted, and `reset_int=1` means reset released/run. Therefore, platform init must enable the clock first, then release ICN reset and the target subsystem reset, and only then access accelerator local registers.
3. If IRQ is used, also enable the subsystem IRQ on the SoC controller side. This value is separate from the accelerator-internal `IRQ_ENABLE`, and determines whether the final `irq_o` can be delivered to the CPU side.
4. If PMOD debug is used, configure `pmod_sel` so that the PMOD GPIO of the corresponding subsystem is routed to the external PMOD connector. The current PMOD mux in the Didactic-SoC repo handles subsystem select values from `0` through `4`, so the final HAL must manage the `pmod_sel` value as a constant matching the subsystem slot actually assigned to our team. This value is different from accelerator-internal `SA_PMOD_CTRL.debug_en`. `pmod_sel` selects which subsystem PMOD signals are visible at the external SoC connector, while `SA_PMOD_CTRL.debug_en` determines whether our subsystem actually drives the PMOD pins as debug outputs.
5. Only after that should firmware access accelerator-internal `CONFIG`, `DIM`, `CONTROL`, `ROW_INJECT_DATA`, `OUTPUT_STATUS`, and `OUTPUT_READ_WINDOW` using `SS_BASE + local_offset` addresses.

The `ss_ctrl_i[7:0]` bus entering the subsystem from the SoC is the control bus that delivers the result of this platform controller configuration to the subsystem.  
Bit 0 of this bus is used as standard clock enable, and bit 1 is used as fast clock enable.  
The important point is that `ss_ctrl_i` does not replace the accelerator-internal `CONTROL` register.  
`ss_ctrl_i` is upper-level control that enables the SoC to make the subsystem usable, while accelerator-internal `CONTROL.start` is the accelerator's own command to actually start one tile computation.

The accelerator-internal `CONTROL.start` and the SoC controller's subsystem enable/reset are controls at different layers.  
The SoC controller configuration means "create the power/clock/reset/route conditions under which the subsystem can operate", while accelerator-internal `CONTROL.start` means "inside the already enabled subsystem, start this tile operation". If these two stages are mixed together, the firmware bring-up sequence becomes unclear.

The very important point here is that both weight and activation enter through the same APB local window, `ROW_INJECT_DATA`.  
Firmware does not use separate weight data and activation data addresses.  
If the current FSM phase is `WEIGHT_MAP`, the same write is interpreted as a weight; if it is `ACT_STREAM_COMPUTE`, it is interpreted as an activation.

From the firmware perspective, the important points are register setup and data push order.  
`CONFIG` and `DIM` are written first because hardware must know in advance how to interpret the 32-bit words that will arrive later.  
For example, the same data word `0x000000FF` becomes several small elements if interpreted as `INT4`, and becomes one element if interpreted as `INT32`. If this interpretation standard changes after start, data already injected and data injected later would have different meanings.

The reason the FSM phase changes after writing `CONTROL.start` is connected to this.  
Even if firmware writes to the same `ROW_INJECT_DATA` address, hardware looks at the phase and decides, "the data currently entering is for weight mapping" or "the data currently entering is for activation streaming". 
Therefore, firmware must not only use the correct address; it must also insert data based on `STATUS.phase` or the defined execution order.

### 3.2 Normal Execution Sequence from the Hardware Perspective

Inside hardware, the following flow occurs.

1. The APB Slave I/F receives an APB transaction and converts it into internal bus signals.
2. The Address Decoder looks at `local_addr` and decides whether the access is a register access, row injection access, or output read access.
3. The RegBank stores configuration fields and exposes status fields to firmware.
4. The Main Control FSM sees `CONTROL.start` and moves from `IDLE_CFG` to `WEIGHT_MAP`.
5. In `WEIGHT_MAP`, when a `ROW_INJECT_DATA` write occurs, a row injection token is created.
6. The Precision Row Injection Frontend interprets the 32-bit packed word as element lanes according to the current precision.
7. Row Injection FIFO/Staging temporarily stores the token or lane data and handles backpressure.
8. The SA Injection Scheduler aligns row timing and mode and forwards the token to the SA Core.
9. Inside the SA Core, the PE loads the weight token delivered during the `WEIGHT_MAP` phase into PE-local weight state.
10. When the FSM moves to `ACT_STREAM_COMPUTE`, the same row injection path is used as the activation stream.
11. The PE uses activation tokens and PE-local weights to perform internal multiply-accumulate operations.
12. The PE internal compute logic uses the received activation, weight, and previous partial accumulation information to produce the next partial result or final result.
13. The SA Core formats the PE internal computation result into the SA result interface format.
14. When a computation result becomes available, the SA Core sends `result_valid` and the result payload to the Output block.
15. If the Output block asserts `result_ready=1`, that result is accepted.
16. The FSM checks whether the required number of results has been accepted and moves to `DONE`.
17. When firmware reads `OUTPUT_READ_WINDOW`, the Address Decoder passes the window offset to the Output block, and the Output block provides the corresponding 32-bit output word as APB read data.

In this flow, the FSM does not need to know what storage structure the Output block uses internally.  
The FSM only observes whether results were accepted by the Output block and whether a result exists that firmware can read.

From the hardware perspective, an APB write does not immediately enter the PE.  
First, the APB I/F converts the bus transaction into an internal write event, the Decoder checks whether the address is the row injection window, the Frontend unpacks it according to precision, and then the Scheduler delivers it with timing suitable for the SA.  
The reason for splitting the path into stages is to keep each block's responsibility small. The APB I/F does not need to know precision, and the PE internal computation logic does not need to know the APB address.

Each stage also has a contract where it receives the previous stage's output and passes something to the next stage.  
For example, the Frontend is responsible for "turning a 32-bit APB word into signed lane data". The Scheduler is responsible for "delivering that lane data according to SA row timing". The PE internal computation path is responsible for "computing using the delivered signed operands". 
This responsibility separation must be clear so that even if team members implement their modules independently, the modules can be connected at the top level.

### 3.3 Why We Put Weights and Activations Through the Same Path

The main direction of our design is to keep the input buffer small.  
Therefore, we avoid a structure with large separate external buffers for weights and activations.

Instead, APB write data passes through the same row injection frontend.  
This path interprets a 32-bit APB word according to precision and converts it into a form that can be inserted into the SA by row.

The difference between weight and activation is determined by the control phase, not by the data path.

- `WEIGHT_MAP`: incoming data is interpreted as weight.
- `ACT_STREAM_COMPUTE`: incoming data is interpreted as activation.

This method simplifies the APB/Decoder/RegBank interface.  
It also allows the Scheduler and SA Core owners to handle both weight mapping and activation streaming using the same form of row input contract.

The core of this policy is to keep one data path and only change the control meaning.  
Separating APB windows for weights and activations may look easier at first, but similar functions can be duplicated across the Decoder, Frontend, FIFO, and Scheduler.  
Because our goal is to keep the input buffer and surrounding control logic as small and clear as possible, using a common path and distinguishing the meaning by FSM phase is more consistent.

Of course, with this method the firmware sequence is important.  
If firmware inserts weights outside `WEIGHT_MAP`, or inserts activations outside `ACT_STREAM_COMPUTE`, then even though the address is the same, the meaning is wrong.  
Therefore, the FSM and Decoder must check state legality, and invalid sequences must be handled as `ERROR`.

### 3.4 Why the Output Format Is Not Fixed at the Top Level

The exact bit width and storage method of output results can differ depending on the internal design of the SA Core and Output block.  
For example, the result representation can vary depending on the internal MAC structure, accumulation method, precision combination, and tile length.

Therefore, the top level does not fix a specific result width or a specific storage method.  
Instead, it fixes only the following protocol and firmware-visible read method.

- The SA Core sends `result_valid`, `result_row`, `result_col`, `result_data`, and `result_last` to the Output block.
- The Output block responds with `result_ready=1` when it can accept.
- The Output block places SA results into an output read window that firmware can read.
- Since APB is 32-bit, firmware directly reads `OUTPUT_READ_WINDOW` in 32-bit word units.
- The Output block exposes `out_window_words`, `out_words_per_element`, and `out_format_id` so firmware can know how many words to read and how to interpret them.

With this, even if the Output owner changes the internal storage structure, APB/RegBank/FSM can remain unchanged.

The reason the output format is not fixed at the top level is that this decision strongly depends on the actual computation datapath and storage structure.  
What result payload width the PE owner uses, and in what word order the Output owner exposes that value to firmware, are still internal implementation choices.  
If the top-level owner arbitrarily fixes this detailed format, it can make it difficult for the Output owner to choose a more suitable structure.

Instead, the top level only fixes the address system firmware uses to read results.  
Firmware reads addresses of the form `SS_BASE + 0x400 + word_index * 4` and receives results as a 32-bit word array.  
Which output element and which word within that element a `word_index` corresponds to is described by `out_words_per_element`, `out_window_words`, and `out_format_id`.

This method makes the firmware loop simpler and reduces APB transactions compared to a method that sets a separate output address register and word select register every time.  
Because APB is not a fast bus, a structure where firmware must first write an address register and word select register for every output word can create large software overhead.  
Therefore, in the final contract, output is exposed as a direct memory-mapped read window.

---

## 4. Addressing and APB Basic Rules

### 4.1 Absolute Base Address Is Not Finalized Yet

It has not yet been finalized which student subsystem slot our subsystem will be assigned to.  
Therefore, this document and RTL do not use a specific absolute base address as the final spec.

All firmware-visible addresses are expressed in the following form.

```text
SS_BASE + local_offset
```

Inside RTL, only `local_addr = PADDR[11:0]` is decoded.

This principle must be applied not only to documentation and RTL, but also to the testbench.  
If the testbench depends on a specific absolute address, the testbench must also be modified when the subsystem slot changes.  
In contrast, if tests are written based on local offsets, the same tests can be reused by changing only the base address.

### 4.2 Local Address Region

The 4 KiB local window is divided as follows.

| Local Range | Purpose | Description |
|---|---|---|
| `0x000-0x0FF` | Control/status/config/output metadata register | Region where firmware configures settings and reads status and output metadata |
| `0x100-0x1FF` | `ROW_INJECT_DATA` window | Region used to push weights and activations through the common path |
| `0x200-0x3FF` | Reserved | Reserved for future extension or debug |
| `0x400-0x4FF` | `OUTPUT_READ_WINDOW` | Region where firmware directly reads completed tile results in 32-bit word units |
| `0x500-0xFFF` | Reserved | Reserved for future extension or debug |

Using `PADDR[11:8]` as a large region selector and `PADDR[7:0]` as a detailed register or detailed window offset is valid.  
For example, the `0x000` region can be treated as the register bank, and the `0x100` region as row injection data.

However, not every address inside the row injection window needs to be treated as a different register.  
All aligned writes in the `0x100-0x1FF` range can be interpreted as a "row injection push". 
In that case, lower address bits can be used as row index, lane group, debug tag, or can be completely ignored.  
This detailed policy must be clearly defined between the Address Decoder and the Row Injection Frontend.

Viewing `PADDR[11:8]` as the large region is also helpful for beginners to understand the memory map.  
If the upper nibble is `0x0`, it is the control/status region; if it is `0x1`, it is the row injection region.  
However, this is only a structure to make internal decoding convenient. It does not mean the entire 4 KiB must be densely used. Unused regions should remain reserved, which is safer for future extension.

Output is mapped to the direct read window at `0x400-0x4FF`.  
This window is the space through which firmware reads completed tile results as a 32-bit word array.  
When the CPU reads `SS_BASE + 0x400 + word_index * 4`, the Address Decoder passes `word_index` to the Output block, and the Output block returns the corresponding output word through `PRDATA[31:0]`.

The reason for choosing this method is to reduce output read control flow.  
If every output word required writing a separate address register and select register first, the number of APB accesses would increase.  
Because APB is not a fast data streaming bus, it is better to make the result read path a simple sequential read loop.

However, the fact that the output window looks like memory does not force the Output block internal implementation to be SRAM.  
The top-level contract only fixes the external behavior: "if this address is read, the corresponding 32-bit output word must be returned". 
The Output owner may internally use SRAM, a register file, a packed buffer, or any other structure as long as this direct read window contract is satisfied.

### 4.3 APB Full-Word Access

Our subsystem uses 32-bit aligned full-word access as the baseline.

The normal access conditions are as follows.

- `local_addr[1:0] == 2'b00`
- Register read/write is in 32-bit units
- `ROW_INJECT_DATA` write is also in 32-bit units
- Output read is also in 32-bit units

Unaligned access is not considered normal operation.  
The Address Decoder must connect such access to `bus_err` or `PSLVERR`.

Fixing full-word access allows the RegBank and Frontend to assume that "a complete 32-bit value always arrives". 
This assumption simplifies `ROW_INJECT_DATA` packing. For example, if the precision is `INT8`, one word consistently contains four elements; if it is `INT16`, one word contains two elements.  
If half-word writes or byte writes were allowed, we would have to define situations where only part of an existing word is updated, making the meaning of a row injection token more complex.

Treating unaligned access as an error also helps find firmware bugs early.  
If a misaligned address is silently ignored or only partially processed, the firmware writer may believe the data entered normally.  
In contrast, exposing the problem through `PSLVERR` or `ERROR_CODE` allows invalid HAL code or pointer calculations to be found quickly during verification.

### 4.4 Why Wait States Are Needed

Our normal operation goal is to complete APB transactions without wait by asserting `PREADY=1` during the APB access phase.  
In particular, normal register read/write, normal `ROW_INJECT_DATA` write, and prepared `OUTPUT_READ_WINDOW` read should avoid unnecessary waits.

However, the APB Slave I/F must be able to insert wait states.  
This feature is not for slowing down the normal performance path. It is a safety mechanism to prevent data loss when an internal block temporarily cannot receive data.

For example, waiting must be possible in the following situations.

- Row injection FIFO or staging is full and cannot receive new data
- The Output block has not yet prepared the requested output window word
- Internal state is not yet stable immediately after reset, clear, or state transition
- The PE internal computation path or SA Core internal pipeline temporarily stops accepting

In these cases, the APB Slave I/F can hold the transaction by driving `PREADY=0`.  
Then, from the firmware perspective, the write/read has not completed yet, so internal data is not lost.

In contrast, there is no reason to wait for an invalid address, unaligned access, or an access not allowed in the current state.  
For these cases, completing quickly with `PREADY=1` and `PSLVERR=1` is clearer for verification and firmware handling.

The behavior we must avoid most is completing an APB transaction with `PREADY=1` even though the internal block cannot accept data.  
In that case, firmware believes the data was delivered correctly, but in the actual internal data path the data can be dropped.

Therefore, wait states should be understood as an exception-case safety mechanism, not the default behavior of the normal path.  
The normal design goal is to provide enough internal staging and pipeline so that the subsystem responds quickly with `PREADY=1`.  
However, if an internal block is not ready, the system must be able to wait, and invalid accesses that cannot be solved by waiting must end as errors.  
Separating these two policies allows us to satisfy both the performance goal and the safety goal.

---

## 5. Firmware-visible Register Map

This section explains the registers that firmware can access.  
Every register is described using the local offset. The actual firmware address is `SS_BASE + local_offset`.

When reading the register map, the first distinction to make is between registers where firmware writes values to define hardware behavior and registers where firmware reads values to observe hardware status.  
`CONTROL`, `CONFIG`, `DIM`, `IRQ_ENABLE`, and `SA_PMOD_CTRL` are registers that firmware writes to communicate intent.  
In contrast, `STATUS`, the count registers, `ERROR_CODE`, `OUTPUT_STATUS`, `OUTPUT_WORDS`, `CAPABILITY_*`, `SA_PMOD_GPI`, and `DEBUG_CYCLE` are registers that hardware provides so firmware can understand the current state and the output read method.

This distinction matters for the RegBank implementation.  
Configuration registers should only be writable before `start`, and status registers must not be overwritten arbitrarily by firmware.  
Command bits should be interpreted as events meaning "execute this command now", not simply as stored values.  
Therefore, the RegBank should be understood not as a plain array of 32-bit registers, but as a control block that manages when each field can be written and when each field is updated by hardware.

### 5.1 Register Summary Table

| Offset | Name | Access | Main Fields | Purpose |
|---|---|---|---|---|
| `0x000` | `CONTROL` | WO or RW | `start`, `soft_reset`, `clear_done`, `clear_error` | Start execution, soft reset, clear sticky status |
| `0x004` | `STATUS` | RO | `busy`, `done`, `error`, `phase`, `phase_detail`, `result_valid`, `output_busy` | Check current accelerator state |
| `0x008` | `CONFIG` | restricted RW | `act_prec`, `wgt_prec`, signed indicator | Set precision |
| `0x00C` | `DIM` | restricted RW | `tile_m`, `tile_n`, `tile_k` | Set current tile size |
| `0x010` | `WEIGHT_COUNT` | RO/debug | count | Weight push progress |
| `0x014` | `INPUT_COUNT` | RO/debug | count | Activation push progress |
| `0x018` | `DRAIN_COUNT` | RO/debug | count | Result drain progress |
| `0x01C` | `OUT_COUNT` | RO/debug | count | Number of results accepted by the Output block |
| `0x020` | `ERROR_CODE` | RO, W1C policy possible | code | Check the cause of `ERROR` |
| `0x024` | `OUTPUT_STATUS` | RO | valid, busy, ready, format | Output window state and format metadata |
| `0x028` | `OUTPUT_WORDS` | RO | valid word count | Number of 32-bit words used by the current tile result |
| `0x02C` | `OUTPUT_WINDOW_BASE` | RO | `0x400` | Starting local offset of the direct output read window |
| `0x030` | `OUTPUT_WINDOW_SIZE` | RO | `0x100` | Byte size of the direct output read window |
| `0x034` | `IRQ_STATUS` | RW/W1C | done irq, error irq | Interrupt pending state |
| `0x038` | `IRQ_ENABLE` | RW | enable bits | Local interrupt enable |
| `0x03C` | `CAPABILITY_0` | RO | max dimensions | Hardware dimension information |
| `0x040` | `CAPABILITY_1` | RO | precision support, output format info | Hardware feature information |
| `0x044` | `SA_PMOD_CTRL` | RW | debug enable, page | Accelerator-local PMOD debug output control |
| `0x048` | `SA_PMOD_GPI` | RO | input pins | Observe accelerator-local PMOD input pins |
| `0x04C` | `DEBUG_CYCLE` | RO/debug | cycle count | Execution time or debug counter |
| `0x100-0x1FF` | `ROW_INJECT_DATA` | WO | packed 32-bit word | Shared weight/activation data push |
| `0x400-0x4FF` | `OUTPUT_READ_WINDOW` | RO | 32-bit word array | Direct read of completed tile result |

### 5.2 `CONTROL`

`CONTROL` is the register through which firmware gives commands to the accelerator.  
In general, when firmware writes 1 to a command bit, hardware should receive it as a pulse and process it.

`CONTROL` is needed to separate configuration values from execution commands.  
`CONFIG` and `DIM` describe the conditions of the tile that will be executed, while `CONTROL.start` is the command to actually begin execution using those conditions.  
Keeping these separate allows firmware to write precision, dimension, IRQ, and PMOD settings in a stable order, and then start the job with one final `start`.

The main fields are:

- `start`: starts tile execution using the current `CONFIG` and `DIM` settings.
- `soft_reset`: initializes internal subsystem state.
- `clear_done`: clears the `DONE` state or done sticky bit.
- `clear_error`: clears the `ERROR` state or error sticky bit.

It is clearest to treat `start` as a legal command only in `IDLE_CFG`.  
If firmware writes `start` again while `busy=1`, the implementation could ignore it or treat it as an illegal sequence. From a team contract perspective, treating it as an illegal sequence is easier to verify.

`soft_reset` is the strongest recovery command.  
It is used to return the FSM, counters, sticky status, row injection staging, and similar internal state to the initial state.  
However, the RegBank policy must clearly define whether settings such as PMOD debug configuration are also cleared or preserved after soft reset.

`clear_done` and `clear_error` are separated from `soft_reset` because they have different recovery strengths.  
`clear_done` clears the normal completion indication and prepares for the next job.  
`clear_error` clears the error indication and allows control to restart.  
In contrast, `soft_reset` is a stronger command that initializes the entire internal progress state, so using it every time firmware only wants to clear the done bit may not be appropriate.

Command bits usually matter only at the moment firmware writes 1.  
Therefore, inside the RegBank, it is natural to convert them into one-cycle pulses such as `start_cmd`, `clear_done_cmd`, and `clear_error_cmd`.  
If a command bit remains stored as 1, the FSM may interpret it as receiving the same command repeatedly.

### 5.3 `STATUS`

`STATUS` is the register firmware reads to check the current accelerator state.

`STATUS` is needed because firmware cannot directly observe many hardware-internal state signals.  
In C code, firmware can only read registers. Therefore, it needs one place where it can check whether the accelerator is waiting for configuration, receiving weights, receiving activations, organizing results, or completed.

The main fields mean:

- `busy`: 1 when the accelerator is currently executing a tile job.
- `done`: 1 when the tile job has completed and result read is possible.
- `error`: 1 when a control error such as illegal sequence, invalid address, or invalid configuration occurs.
- `phase`: shows the current FSM state as a number.
- `phase_detail`: provides more detailed progress information inside the current phase.
- `result_valid`: 1 when the Output block has a result firmware can read.
- `output_busy`: 1 when the Output block is internally processing a read/write action.

`phase` shows the large state, while `phase_detail` shows finer progress.  
If the top-level FSM has too many states, firmware control and verification become more complicated.  
Therefore, the large FSM state is kept to six states, and detailed progress is observed through counters and `phase_detail`.

`busy`, `done`, and `error` are summary bits that allow firmware to branch quickly.  
If `busy=1`, firmware must not write new `CONFIG` or `DIM`. If `done=1`, firmware can try to read the result after normal completion. If `error=1`, firmware should read `ERROR_CODE` and enter a recovery sequence.  
These three bits make the high-level firmware flow simpler.

`phase` and `phase_detail` are for more detailed control and debugging.  
For example, `busy=1` alone does not tell firmware whether it should send weight data or activation data.  
`phase` is needed so the HAL or testbench can determine which APB accesses are legal at that moment.  
`phase_detail` can be used to show which token, which internal step, or which finer progress point has been reached within the same phase.

### 5.4 `CONFIG`

`CONFIG` stores the precision settings.

`CONFIG` is needed because the same 32-bit APB data word is interpreted very differently depending on precision.  
The activation and weight bit widths can vary depending on the matrix data type used by firmware.  
Hardware must know this precision information before data arrives so it can correctly unpack each `ROW_INJECT_DATA` word.

The precision encoding is fixed as follows.

| Encoding | Precision |
|---|---|
| `00` | `INT4` |
| `01` | `INT8` |
| `10` | `INT16` |
| `11` | `INT32` |

`act_prec` and `wgt_prec` exist independently.  
Therefore, activation and weight can form all 16 combinations.

Activation precision and weight precision are separated because the two operands do not always have the same bit width.  
For example, activation may be `INT16` while weight is `INT8`.  
If there were only one precision field, such combinations could not be represented, so `act_prec` and `wgt_prec` must be separate fields.

All operands are interpreted as signed two's complement.  
Unsigned mode or runtime signedness switching is not part of this top-level contract.

`CONFIG` should preferably be writable only in `IDLE_CFG`.  
If precision changes during computation, the data that has already entered and the data that will enter later are interpreted differently, making the result undefined.  
Therefore, a `CONFIG` write while `busy=1` should be treated as an illegal access.

This restriction is not intended to make firmware inconvenient. It guarantees that all data in one tile uses the same interpretation rule.  
If earlier weights are unpacked as `INT8` and later weights are unpacked as `INT16`, weight mapping inside the SA and MAC inputs would follow different standards.  
Because hardware cannot easily fix such a situation automatically, precision changes after `start` must be blocked at the Decoder, RegBank, or FSM level.

### 5.5 `DIM`

`DIM` sets the current tile size.

`DIM` is needed because hardware must know how many weight tokens, activation tokens, and results to expect for this tile.  
The FSM uses this information to decide when to finish `WEIGHT_MAP`, when to finish `ACT_STREAM_COMPUTE`, and how many results must be accepted in `DRAIN_WRITEBACK` before moving to `DONE`.

The recommended field layout is:

- `tile_m[7:0]`: number of output rows
- `tile_n[15:8]`: number of output columns
- `tile_k[23:16]`: dot product length

The baseline array assumes 8x8, but the RTL must be parameterized.  
Therefore, `tile_m`, `tile_n`, and `tile_k` are valid only within the range allowed by the current hardware parameters.

`DIM` is not the full matrix size.  
The full matrix size and tiling loop are managed by firmware.  
Hardware processes only "one tile that is currently entering".

`DIM` should also preferably be writable only in `IDLE_CFG`.  
If the dimension changes during tile execution, the weight count, activation count, and expected result count all change.

The fact that `DIM` is the tile size, not the full matrix size, is important for firmware and HAL design.  
For example, even if the full matrix is 32x32, if hardware processes one 8x8 tile at a time, `DIM` contains only the size needed for the current 8x8 tile.  
When firmware moves to the next tile, it prepares the tile position and data sequence again.  
This allows hardware to focus on processing a small tile while firmware manages traversal of the full matrix.

### 5.6 Count Registers

`WEIGHT_COUNT`, `INPUT_COUNT`, `DRAIN_COUNT`, and `OUT_COUNT` are registers used by firmware and verification environments to check progress.

These count registers are not necessarily control inputs required for normal operation, but they are very important for debugging and verification.  
During early bring-up, if the accelerator stops, `STATUS.phase` alone may not be enough to identify where it stopped.  
For example, if it remains in `WEIGHT_MAP`, we may need to distinguish whether not enough weight writes were issued, whether the Frontend failed to create tokens, or whether the Scheduler could not accept them. Count registers provide observation points that narrow down such situations.

- `WEIGHT_COUNT`: counts accepted 32-bit `ROW_INJECT_DATA` weight writes in `WEIGHT_MAP`.
- `INPUT_COUNT`: counts accepted 32-bit `ROW_INJECT_DATA` activation writes in `ACT_STREAM_COMPUTE`.
- `DRAIN_COUNT`: counts progress as results are drained from the SA Core.
- `OUT_COUNT`: counts the number of results accepted by the Output block.

The exact meaning of each counter must be clear in the module-to-module contract.  
For example, if it is unclear whether `WEIGHT_COUNT` counts APB write words, unpacked elements, or row tokens, verification becomes difficult.

At the top level, the policy is fixed as follows.

- `WEIGHT_COUNT` and `INPUT_COUNT` count accepted 32-bit `ROW_INJECT_DATA` write words.
- How many elements inside one word were valid can be observed separately through `lane_count` or Frontend/debug internal state.
- Output-related counters count result elements accepted by `result_valid && result_ready`.

The counter basis must be used with the same meaning by the entire team.  
If one module counts APB write words and another module counts unpacked elements, team members can draw different conclusions from the same counter name.  
Because firmware writes `ROW_INJECT_DATA` in 32-bit word units, the firmware-visible count is simplest when it also follows word units.  
Therefore, whether a count is based on "APB words", "tokens", or "result elements" must be consistent in the document, RTL comments, and testbench.

### 5.7 `ERROR_CODE`

`ERROR_CODE` is the register firmware reads to identify why the accelerator entered `ERROR`.

`ERROR_CODE` is needed because `STATUS.error=1` alone does not explain what needs to be fixed.  
From the firmware perspective, an error may have many causes. The address may be wrong, the state sequence may be wrong, or firmware may have tried to read output before the result was ready.  
With `ERROR_CODE`, firmware/HAL and the testbench can classify the failure cause accurately.

Expected error codes include:

| Error | Meaning |
|---|---|
| invalid address | Access to an unassigned local address |
| unaligned access | Access that is not 32-bit aligned |
| illegal state access | Access not allowed in the current FSM state |
| invalid tile dimension | `DIM` value is outside the hardware-supported range |
| output read before result | `OUTPUT_READ_WINDOW` was read when there was no result |
| output window out of range | Read address is outside the valid range indicated by `OUTPUT_WORDS` |

`ERROR` represents a violation of the top-level control contract.  
The SA internal numeric policy is not included in this error path.

`ERROR_CODE` should preferably be sticky.  
Firmware may not read it immediately after the error occurs.  
The recorded error reason should remain until `clear_error` or `soft_reset`, so bring-up and simulation do not lose the cause.

The error described here is a violation of the agreement between firmware and top-level control flow.  
The PE internal numeric representation, result format selection, and internal arithmetic policy are responsibilities of separate modules and should not be mixed directly into this top-level `ERROR`.  
Keeping this separation prevents firmware from confusing control errors with internal computation policy.

### 5.8 Output Read Window and Metadata Registers

Output read uses a direct memory-mapped read window.

The output read window is needed to reduce the number of APB transactions required to read results.  
APB is not a high-bandwidth streaming bus, so a method that requires firmware to write several control registers before reading each output word can be inefficient.  
Therefore, the final contract exposes the completed tile result as a 32-bit word array in the `0x400-0x4FF` range.

Firmware reads output words using the following address form.

```text
output_word_addr = SS_BASE + 0x400 + word_index * 4
```

`word_index=0` is the first 32-bit word of the current tile output, and `word_index=1` is the next 32-bit word.  
Regardless of its internal storage method, the Output block must return the 32-bit data corresponding to this read request.

The registers and window used are:

- `OUTPUT_STATUS`: reports output window state, whether the Output block is busy, and format information. It is closer to status/debug information than a register that normal firmware loops must check before every word.
- `OUTPUT_WORDS`: reports how many 32-bit words the current tile result occupies inside `OUTPUT_READ_WINDOW`.
- `OUTPUT_WINDOW_BASE`: local offset of the direct output read window. The default is `0x400`.
- `OUTPUT_WINDOW_SIZE`: byte size of the direct output read window. The default is `0x100`.
- `OUTPUT_READ_WINDOW`: the address window where actual result data is read in 32-bit word units.

The firmware read sequence is:

1. Poll until `STATUS.done` or `STATUS.result_valid` becomes 1, or wait for the done IRQ.
2. Read `OUTPUT_WORDS` to determine how many 32-bit words must be read.
3. Starting from `SS_BASE + 0x400`, perform 32-bit reads for `OUTPUT_WORDS` words.
4. If needed, read `OUTPUT_STATUS` or `CAPABILITY_1` to check format/debug information.

`OUTPUT_STATUS.window_ready` is not a control signal that must be polled in every normal execution.  
The goal is that after `DONE` or done IRQ, output window reads are immediately possible and each read can be processed without APB wait.  
However, if the Output block implementation has read latency longer than one cycle, it can create an APB wait state through `out_window_ready=0`, and this status is exposed through `OUTPUT_STATUS` for firmware/debug observation.

In this method, IRQ is not the signal that transfers data.  
IRQ is an event signal that tells the CPU "the tile result is ready in the output read window".  
The actual result data moves when the CPU performs APB reads from `OUTPUT_READ_WINDOW`.

The final contract does not include a method that generates an interrupt every time part of the output becomes ready.  
Our baseline is that after the whole tile result has been accepted by the Output block, the FSM moves to `DONE`, and at that point `result_valid` and the done IRQ notify firmware that readback is possible.  
In other words, we do not use a streaming protocol where the CPU is woken up whenever the output buffer becomes partially full to remove some results.

The Output block owner decides the output result width and internal format.  
The top level exposes `out_window_words`, `out_words_per_element`, and `out_format_id` as metadata so firmware knows how many words to read.  
Without this information, firmware would have to hardcode the output format, and the HAL would need large changes whenever the Output owner changes the format.

### 5.9 IRQ Registers

`IRQ_STATUS` stores the interrupt pending state.  
The recommended policy is sticky W1C.

IRQ registers are needed so firmware does not always have to rely only on polling.  
With polling, the CPU must repeatedly read `STATUS.done` or `STATUS.error`.  
With IRQ, the accelerator can notify the CPU of a done or error event, so firmware can do other work and then handle the interrupt.

Sticky W1C means:

- When an event occurs, the corresponding status bit is set to 1.
- Firmware clears that bit by writing 1 to it.
- Writing 0 keeps the bit unchanged.

`IRQ_ENABLE` is the local interrupt enable.  
The actual `irq_o` output must pass through both the local enable and the `irq_en_i` gate coming from the SoC.

`IRQ_STATUS` and `irq_o` have different roles.  
`irq_o` is a short event signal going toward the CPU, while `IRQ_STATUS` is a register state that remains so firmware can later read which event occurred.  
Therefore, even if the `irq_o` pulse is missed, firmware should still be able to read `IRQ_STATUS` and determine what event happened.

### 5.10 PMOD Registers

`SA_PMOD_CTRL` controls the accelerator-internal PMOD debug output.  
The `SA_` prefix is used because the Didactic-SoC firmware side already has a name `PMOD_CTRL` for the SoC controller PMOD routing register.  
The SoC controller `PMOD_CTRL` is an upper-level routing register that selects which subsystem is connected to the external PMOD connector. The `SA_PMOD_CTRL` defined here is a local register that selects the debug output enable/page inside our accelerator. These two registers have different address spaces and roles, so separating the names in the firmware header reduces confusion.

PMOD registers are needed so internal state that is difficult to observe through simulation or firmware polling alone can be seen on external pins.  
During FPGA bring-up, values such as `phase`, `busy`, `done`, `error`, and some counter bits can be sent to PMOD to quickly check which stage the hardware is actually in.

The recommended fields are:

- `debug_en`: enable PMOD debug output
- `debug_page`: select which debug signal group is shown on the PMOD pins

`SA_PMOD_GPI` is an accelerator-local register through which firmware reads PMOD input pin values.  
In the SoC Documentation and student subsystem examples, the PMOD interface is represented as two 4-bit GPIO ports.

- `pmod_0_gpi[3:0]`, `pmod_0_gpo[3:0]`, `pmod_0_gpio_oe[3:0]`
- `pmod_1_gpi[3:0]`, `pmod_1_gpo[3:0]`, `pmod_1_gpio_oe[3:0]`

Therefore, the accelerator's logical PMOD debug payload is defined as 8 bits.  
`SA_PMOD_GPI` gathers these eight input pins for easier firmware reading. In this document, `SA_PMOD_GPI[3:0] = pmod_0_gpi[3:0]`, `SA_PMOD_GPI[7:4] = pmod_1_gpi[3:0]`, and `SA_PMOD_GPI[31:8] = 0`.

However, some current generated top/wrapper files in the Didactic-SoC repo express subsystem PMOD as a 16-bit GPIO bus.  
This difference is treated as an integration difference that the wrapper adapter should absorb, not as a reason to change the accelerator internal architecture.  
If the final wrapper provides two 4-bit PMOD ports, connect the signals above directly. If the final wrapper provides a 16-bit PMOD bus, connect the logical PMOD debug payload from this document to the lower 8 bits, drive unused upper 8-bit outputs to 0, and leave their output enable in input/tristate mode. With this policy, the core-internal PMOD Debug block only needs to produce an 8-bit debug page, while wrapper representation differences can be handled during top integration.

The output enable polarity of PMOD pins must follow the official SoC document and wrapper convention.  
The current contract uses the following meaning for the two 4-bit ports according to the SoC Documentation.

```text
pmod_0_gpio_oe = debug_en ? 4'h0 : 4'hF
pmod_1_gpio_oe = debug_en ? 4'h0 : 4'hF
```

Here, `0` means output drive, and `1` means input or high impedance.

PMOD is not an essential element of the normal matrix multiplication data path. It is an auxiliary path for debug and bring-up.  
Therefore, it must not be understood as a structure for sending or receiving large data such as weights or activations.  
When `SA_PMOD_CTRL.debug_en=0`, it is safest to keep PMOD pins in input/tristate mode. Only when debug is needed should the selected 8-bit debug page be driven through `pmod_0_gpo`, `pmod_1_gpo`, or the lower 8 bits of the 16-bit wrapper.

### 5.11 `ROW_INJECT_DATA`

`ROW_INJECT_DATA` is the shared data window used to push both weights and activations.

`ROW_INJECT_DATA` is needed because firmware needs a path to send matrix tile data into the accelerator.  
`CONFIG` and `DIM` describe the computation conditions, but actual weight and activation values enter through this window.  
Therefore, this window should be understood not as simple register storage, but as a push port that creates an internal data token on every write.

Firmware writes 32-bit words to this window.  
Whether that word is a weight or activation is not determined by firmware writing a separate mode bit.  
It is determined by the current FSM phase.

- A write in `WEIGHT_MAP` is weight data.
- A write in `ACT_STREAM_COMPUTE` is activation data.
- A write in any other state is an illegal state access.

This policy simplifies the firmware API and the APB address map.  
In exchange, firmware must send data according to the FSM phase.

Because the same address is shared, it is important that firmware does not directly write `row_inject_mode`.  
If firmware directly controlled the mode bit, errors such as writing activation mode while the FSM is in `WEIGHT_MAP` could occur.  
In the current contract, the FSM phase automatically generates the mode, so the rule that only data allowed in the current phase is accepted becomes clearer.

A completed `ROW_INJECT_DATA` write must mean that the internal row injection path has actually accepted that word.  
If the internal path cannot receive data but the APB write still completes, firmware will start sending the next word and the previous word may disappear.  
Therefore, this window must be defined together with backpressure policies such as `PREADY`, `row_inject_ready`, or FIFO ready.

---

## 6. FSM Detailed Description

### 6.1 Overall FSM Structure

The top-level FSM uses the following six states.

```text
IDLE_CFG -> WEIGHT_MAP -> ACT_STREAM_COMPUTE -> DRAIN_WRITEBACK -> DONE
                                  |
                                  v
                                ERROR
```

`ERROR` can be entered from any state.  
The normal flow starts in `IDLE_CFG` and ends in `DONE`.

The FSM is limited to six states so firmware and testbenches can understand the state more easily.  
Internally, there may be many more fine-grained progress states such as weight count, row index, scheduler phase, and PE pipeline stage.  
However, if all such detailed steps are exposed as top-level FSM states, firmware must handle too many states and illegal sequence verification also becomes complicated.  
Therefore, the top level keeps only the large execution phases as states, and detailed progress is observed through counters and status fields such as `phase_detail`.

### 6.2 `IDLE_CFG`

`IDLE_CFG` is the state where the accelerator is ready to receive a new job.

In this state, firmware can perform:

- `CONFIG` write
- `DIM` write
- `IRQ_ENABLE` write
- `SA_PMOD_CTRL` write
- `CONTROL.start` write
- clear of previous state
- output read if a previous result remains

The important point in this state is that row injection data is not accepted yet.  
`ROW_INJECT_DATA` write is legal only in `WEIGHT_MAP` or `ACT_STREAM_COMPUTE`.

`IDLE_CFG` is the stage where pre-execution settings are fixed stably.  
In this stage, firmware organizes precision, tile size, interrupt enable, and debug output settings.  
Only after these values are determined should `start` be issued, so hardware can predict the number and interpretation of data that will enter.

If `ROW_INJECT_DATA` is accepted in `IDLE_CFG`, it is unclear whether the data should be a weight or activation.  
The FSM has not yet entered the weight mapping phase.  
Therefore, blocking data push in this state is an important protection mechanism that enforces firmware ordering.

### 6.3 `WEIGHT_MAP`

`WEIGHT_MAP` is the state where weights are mapped into the internal weight positions of the SA.

The normal operations in this state are:

- Firmware writes weight packed words to `ROW_INJECT_DATA`.
- The Address Decoder interprets this write as a row injection push.
- The Main FSM generates `row_inject_mode=0`.
- The Precision Row Injection Frontend interprets the word using `wgt_prec`.
- The Scheduler and SA Core deliver the data in the form needed for weight mapping.

Activation writes are not a normal sequence in this state.  
Changing `CONFIG` or `DIM` is also not allowed because it would change weight interpretation and expected counts.

The condition for moving from `WEIGHT_MAP` to the next state is "have all required weight tokens been accepted?"  
The concrete form of this condition depends on `tile_m`, `tile_n`, `tile_k`, array shape, and scheduler policy.  
At the top level, the interface must provide counts and done signals so this condition can be judged.

`WEIGHT_MAP` exists as a separate state because, in a weight stationary method, the PE internal weight state must be prepared first.  
Before activations flow in, the required weights must be mapped to each PE or SA internal weight location for computation results to be meaningful.  
Therefore, in this phase, activations are not accepted and only weight tokens are recognized as normal data.

`CONFIG` and `DIM` are blocked in this state for the same reason.  
Weights that have already entered are being mapped using the previous precision and dimension. If the settings change in the middle, earlier weights and later weights are interpreted using different rules.  
This situation can easily create incorrect results, so treating it as an illegal access is clearer.

### 6.4 `ACT_STREAM_COMPUTE`

`ACT_STREAM_COMPUTE` is the state where activations are injected while the SA Core performs computation.

The normal operations in this state are:

- Firmware writes activation packed words to `ROW_INJECT_DATA`.
- The Main FSM generates `row_inject_mode=1`.
- The Precision Row Injection Frontend interprets the word using `act_prec`.
- The Scheduler aligns activation stream timing.
- The SA Core receives activations and performs computation.

The state name includes both `STREAM` and `COMPUTE` because the two operations are not separate sequential stages.  
While activations enter, computation can proceed inside the SA at the same time.

Reinjecting weights in this state is not part of the baseline normal sequence.  
If an extension is needed to reuse weights or process multiple activation batches with the same weights, a separate protocol must be added.

Activation streaming and compute are combined in `ACT_STREAM_COMPUTE` because, due to the behavior of a systolic array, MAC updates can proceed at the same time as activations enter.  
In other words, this design does not first store all activations in a buffer and compute later. Instead, it uses incoming activations directly in the computation flow.  
This matches our strategy of reducing the input buffer.

The important point in this state is not to confuse the number of accepted activation tokens with the amount of computation that has actually completed.  
Even after all activation input has finished, results may still remain inside the SA pipeline.  
Therefore, after activation input completes, the FSM moves to `DRAIN_WRITEBACK` rather than directly to `DONE`.

### 6.5 `DRAIN_WRITEBACK`

`DRAIN_WRITEBACK` is the state where no new input is accepted and remaining results inside the SA are transferred to the Output block.

The normal operations in this state are:

- The SA Core creates a result payload.
- The SA Core asserts `result_valid=1` to indicate that the result is valid.
- When the Output block is ready to receive it, it asserts `result_ready=1`.
- In a cycle where `result_valid && result_ready`, one result is accepted by the Output block.
- The FSM counts the accepted results.

The name `DRAIN_WRITEBACK` does not describe the internal storage method of the Output block.  
This state only has the top-level meaning "results from the SA are moving into the Output block".

When all expected results have been accepted by the Output block, the FSM moves to `DONE`.  
At that time, the Output block must have prepared the result set so firmware can read `OUTPUT_READ_WINDOW`.  
In other words, `DONE` should not mean only that the SA computation has ended. From the top-level perspective, it must also mean that firmware may start reading the output window.

New input is not accepted in this state because the data injection phase required for computation has already finished.  
The key task after that point is to pass valid results remaining inside the SA to the Output block without losing them.  
The storage structure used by the Output block is unrelated to the meaning of this state. The FSM only counts results for which `result_valid && result_ready` is true and determines whether all required results have been delivered.

If `result_ready=0`, the result must not be transferred.  
In that case, the SA Core must hold the result or retry internally.  
The FSM must also not increase the result count in that cycle. The rule that `valid && ready` defines transfer applies here as well.

### 6.6 `DONE`

`DONE` is the state where tile execution has completed normally.

In this state, firmware can perform:

- check `STATUS.done`
- check and clear `IRQ_STATUS`
- check `OUTPUT_STATUS` and `OUTPUT_WORDS`
- read results through `OUTPUT_READ_WINDOW`
- issue `clear_done`
- prepare new settings or a new start sequence for the next tile

For output read to be possible in `DONE`, the Output block's `out_result_valid` must be 1.  
If the result does not exist yet or the output window is not ready, that must be handled clearly through `OUTPUT_STATUS` and the `PSLVERR` policy.

`DONE` is the firmware-visible completion state indicating that the SA has no more computation for this tile and the tile execution ended normally.  
Firmware can use this state to start reading results or to prepare the next tile.  
However, `DONE` itself does not explain the internal format of the Output block. How many 32-bit words must be read and how those words should be interpreted must be checked through `OUTPUT_STATUS`, `OUTPUT_WORDS`, `out_words_per_element`, and `out_format_id`.

A simple baseline policy assumes that firmware reads the current tile result before starting the next tile.  
When a new tile starts, the Output block may overwrite or invalidate the previous result window.  
With this policy, we do not need to require complex read/write conflict control or additional buffering to support output read and next tile compute at the same time.

When starting the next tile, a policy is needed for how to clear the previous `done` state.  
The recommended method is for firmware to clear the completion indication with `clear_done`, write new `CONFIG`/`DIM` in `IDLE_CFG` if needed, and then issue `start` again.  
Whether continuous tile execution with the same settings is allowed must be clearly defined in the HAL and FSM policy.

### 6.7 `ERROR`

`ERROR` is the state entered when a top-level control contract violation occurs.

Expected causes include:

- Access to an unassigned address
- Unaligned access
- `CONFIG` write outside `IDLE_CFG`
- `DIM` write outside `IDLE_CFG`
- Activation push before `WEIGHT_MAP`
- Weight push after `ACT_STREAM_COMPUTE`
- `OUTPUT_READ_WINDOW` read when there is no output result
- Output window address outside the valid range indicated by `OUTPUT_WORDS`

In the `ERROR` state, it is safest to stop injection and computation.  
Recovery is performed through `clear_error` or `soft_reset`.

`ERROR` exists so hardware does not continue when an incorrect control sequence occurs.  
For example, if activations enter before weight mapping is complete, later computation results are difficult to trust under any standard.  
If hardware silently ignores the problem or continues computation, firmware and testbenches will have difficulty finding the issue.

`ERROR` should be treated as a recoverable top-level state.  
Firmware should read `ERROR_CODE` after seeing `STATUS.error`, then return to `IDLE_CFG` through `clear_error` or `soft_reset`.  
Whether the transaction that caused the error is automatically retried is not defined as a separate policy. Firmware should instead execute the correct sequence again.

---

## 7. Row Injection Data Path

### 7.1 Purpose of the Row Injection Path

The row injection path converts 32-bit data words received from APB into a form that the SA Core can receive.

This path is needed because APB write data and the SA Core input form are different.  
APB always provides one 32-bit word, but the SA Core must also know information such as row-level operands, precision-specific elements, valid lanes, and whether the token is weight or activation.  
The row injection path organizes this difference so downstream compute blocks do not need to directly care about APB packing rules.

This path performs the following tasks.

- Checks whether an APB write is an actual data push.
- Determines whether the data is weight or activation according to the current FSM phase.
- Determines the number of elements inside the 32-bit word according to current precision.
- Interprets each element as signed two's complement.
- Extends the elements into internal lane data.
- Applies backpressure if the next block cannot receive data, preventing data loss.

In other words, the row injection path is not just a wire that passes data through.  
It is a preprocessing path that converts the 32-bit word written by firmware into "a meaningful computation input for the current phase".  
If this path is not clearly defined, the Scheduler, SA Core, and PE may each reimplement precision interpretation and row selection independently, making module-to-module mismatches likely.

### 7.2 Why Only One `ROW_INJECT_DATA` Is Used

Separating weights and activations into different APB windows may look intuitive from the firmware side.  
However, in our design, it is important to keep the input buffer small and share the row-level injection path.

Therefore, the following policy is used.

- The APB address map uses one data push window.
- The meaning of data is determined by the FSM phase.
- Firmware writes data to the same address according to the phase.

This policy simplifies the APB map and reduces the role of the Decoder and RegBank.  
It also allows the row injection frontend, staging, and scheduler to operate based on one data format.

The most important rule in this method is that firmware must follow the phase order.  
Because the address is shared, hardware does not distinguish weight from activation by address alone.  
Instead, if the FSM is in `WEIGHT_MAP`, the word is interpreted as weight, and if the FSM is in `ACT_STREAM_COMPUTE`, the word is interpreted as activation.  
Therefore, the HAL must separate weight writes and activation writes based on `STATUS.phase` or a predefined count sequence after `start`.

This policy also benefits internal block owners.  
The Frontend does not need separate unpackers for weights and activations. It can create lanes using the same mechanism based on mode and precision.  
The Scheduler can also receive the same token form and only apply different SA internal control according to the phase.

### 7.3 32-bit Packing by Precision

APB write data is always 32 bits.  
The number of elements inside one 32-bit word changes depending on precision.

| Precision | Elements per 32-bit Word | Layout |
|---|---:|---|
| `INT4` | 8 | 4 bits each from LSB upward |
| `INT8` | 4 | 8 bits each from LSB upward |
| `INT16` | 2 | 16 bits each from LSB upward |
| `INT32` | 1 | full 32-bit word |

For example, with `INT8`, `bus_wdata[7:0]` is the first element and `bus_wdata[15:8]` is the second element.  
The element on the LSB side is always interpreted as the element that entered first.

The maximum number of elements that can come from one APB word is 8, based on `INT4`.  
Therefore, the row injection lane vector width is defined using `INJECT_LANES_MAX=8`, independent of the number of SA array rows.  
Because the current baseline is 8x8, `ARRAY_ROWS=8` and `INJECT_LANES_MAX=8` may appear to be the same, but they mean different things.  
`ARRAY_ROWS` is the number of rows in the SA Core, while `INJECT_LANES_MAX` is the maximum number of element lanes that must be represented when one 32-bit APB word is unpacked according to precision.

The packing order is fixed to prevent firmware and hardware from understanding the element order differently.  
When firmware packs matrix data into 32-bit words, hardware must unpack it in the same order so row and column positions match.  
Defining the order as LSB-first gives a clear rule for C/HAL packing functions.

The last word may contain lanes that are not used because of the actual tile size.  
For example, if only three elements remain but an `INT8` word can contain four lanes, the last lane must be treated as padding.  
`lane_valid` is needed so padding lanes do not enter computation.

### 7.4 Signed Two's Complement Interpretation

All operands are interpreted as signed two's complement.

After cutting out elements according to precision, the Frontend must sign-extend them when sending them as internal lane payloads.  
The internal lane width must at least represent `INT32`, so in the top-level signal contract, it is safe to view each lane payload as a 32-bit signed value.

For example, `INT4` element `4'b1111` is interpreted as -1 and extended into a 32-bit signed value.  
This interpretation applies equally to weights and activations.

If the Frontend is responsible for sign extension, the downstream PE compute logic does not need to repeat bit slicing every time depending on the original operand width.  
The PE internal compute path can basically assume it receives 32-bit signed operands, and it can use the precision fields for internal datapath selection or verification information.  
With this division of responsibility, precision packing rules are gathered in one place, which reduces bugs.

Fixing all operands to signed two's complement is also important.  
If signed/unsigned mode changes at runtime, the Frontend, MAC, golden model, and firmware packing functions must all match that mode.  
The current contract keeps one signed interpretation to simplify the standard.

### 7.5 Row Index and Lane Valid

A row injection token needs row information.

The reason is that the SA Core has multiple rows, and it must know which row should receive the same 32-bit word.  
There are several ways to create the row index.

- Use part of the address offset as the row index.
- Increment rows sequentially with an internal counter.
- Let the Scheduler determine the row from the current phase and count.

The top-level contract fixes the following signal meanings.

- `frontend_row_idx`: logical row index where this token will enter
- `lane_valid[INJECT_LANES_MAX-1:0]`: marks valid element lanes inside the current word
- `lane_data[INJECT_LANES_MAX*32-1:0]`: sign-extended element payload

In the last word, not all lanes may be valid depending on tile size.  
This is why `lane_valid` is needed.  
If padded lanes are used as real data in computation, the result can become wrong.

`frontend_row_idx` tells the downstream blocks which logical SA row receives the 32-bit word.  
Without this information, the Scheduler cannot place data by row, and operand position becomes ambiguous in an array with multiple rows.  
Whether the row index comes from address bits, a counter, or the Scheduler is an implementation choice, but in every case a row index understood by downstream blocks must be transferred.

`lane_valid` is separate from row index.  
Row index means "which row this goes to", while lane valid means "which elements inside this word are real data".  
Both signals are needed so invalid elements do not enter computation even for a final partial word or a small tile.

`lane_valid` width is not tied directly to `ARRAY_ROWS` for this reason.  
The number of SA rows represents the array structure, while the number of lanes represents the APB word packing structure.  
In the 8x8 baseline both values are 8, so they may look like the same width, but even if the array size changes later, the maximum number of elements from one `INT4` packed word remains 8.

### 7.6 Backpressure

The row injection path must have backpressure.

The normal goal is to build enough pipeline/staging so the internal path can immediately receive each `ROW_INJECT_DATA` write.  
In other words, during a normal sequence, the row injection frontend and downstream path should keep `ready=1`, and the APB side should complete writes without wait using `PREADY=1`.

However, internal FIFO, staging, Scheduler, or SA Core may temporarily be unable to receive data.  
In that case, the internal `ready=0` state must be propagated to the APB side.

The APB Slave I/F can hold the transaction with `PREADY=0` in such cases.  
Then, from the firmware perspective, the write has not completed yet, so data does not disappear.

The row injection path principles are:

- In normal cases, no-wait accept is the target.
- `ready=0` is for exceptional protection.
- A write that receives `PREADY=1` must be accepted internally.
- The system must not assert `PREADY=1` for a write that cannot be accepted internally.

Implementing backpressure does not mean every normal case must wait.  
On the contrary, the goal is to keep `ready=1` during normal sequences by designing the Frontend, FIFO/Staging, and Scheduler to continuously accept data.  
The reason to keep ready signals is to handle exceptional conditions clearly.

For example, if the FIFO is full and firmware write completes, that word has nowhere to be stored.  
If hardware silently drops it, the result is wrong and the cause is difficult to find.  
Therefore, when full, `frontend_ready=0` must propagate upward, and the APB I/F must either wait with `PREADY=0` or apply a clear error policy.

---

## 8. Output Result Read Path

### 8.1 Purpose of the Output Path

The output path receives results from the SA Core and makes them readable by firmware.

This path is needed because the result form produced by the SA Core and the APB data form read by firmware are different.  
The SA Core creates computation-centered information such as row, column, result payload, and last indication.  
Firmware can read only 32-bit words through APB.  
The output path stores or arranges the results between these two forms and provides a 32-bit word array that firmware can read sequentially through `OUTPUT_READ_WINDOW` at `0x400-0x4FF`.

The Output block is responsible for:

- Accepting SA Core results.
- Storing or arranging results internally.
- Exposing the completed tile result to `OUTPUT_READ_WINDOW` in 32-bit word units.
- Providing the current output format and valid word count as metadata.
- Reporting whether results are readable by firmware.

The top-level FSM does not need to know the internal storage method of the Output block.  
The FSM only observes whether a result has been accepted and whether firmware read is possible.

This separation is important so the internal implementation choice of the Output block does not disturb the top-level control flow.  
Whether the Output owner uses a register file or SRAM, and whichever order results are stored in, the top-level FSM should operate only through the external contract such as `result_valid/result_ready` and `out_result_valid/out_busy/out_window_ready`.  
This allows the APB/Decoder/RegBank/FSM to remain stable even if the Output implementation changes.

### 8.2 Signals from SA Core to Output Block

The SA Core sends the following signals to the Output block.

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `result_valid` | SA Core -> Output | Output Result Interface | Indicates that the current result payload is valid. If this signal is 0, `result_data` must not be treated as meaningful. |
| `result_row` | SA Core -> Output | Output Result Interface | Row index of the result. The Output block can use this to decide where the result belongs in the output window. |
| `result_col` | SA Core -> Output | Output Result Interface | Column index of the result. This is needed to match output element positions during firmware readback and golden comparison. |
| `result_data[RESULT_W-1:0]` | SA Core -> Output | Output Result Interface | Result payload. Width and format are not fixed at the top level; they are exposed through the SA/Output contract and capability metadata. |
| `result_last` | SA Core -> Output | Output Result Interface/FSM | Marks the last result of the current tile. The FSM and Output block can use it to confirm tile completion. |
| `result_ready` | Output -> SA Core/FSM | SA Core, Main FSM | Indicates that the Output block can accept a result. If 0, the SA Core must keep the result without losing it. |

Actual result transfer occurs only when `result_valid && result_ready`.  
If the Output block cannot receive a result, it can apply backpressure with `result_ready=0`.

`result_valid` is the SA Core saying "the result payload is meaningful now".  
`result_ready` is the Output block saying "I can store or process that result now".  
If only one of the two is 1, the transfer has not yet happened. This rule prevents result loss even if the Output block is temporarily not ready.

`result_row` and `result_col` tell where the result belongs inside the output tile.  
The Output block can use this position information to create a word order inside the direct read window. For example, if it chooses row-major layout, it can convert `(row, col)` into a linear element index and store the result at the 32-bit word position for that element.  
However, whether the layout is row-major or another mapping is decided by the Output owner, and its interpretation can be explained through `out_format_id` and the Output owner's document.

### 8.3 Firmware Direct Output Window Read Signals

The Address Decoder/APB side sends the following direct read requests to the Output block.

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `out_window_re` | Address Decoder/APB -> Output | Output Result Interface | Indicates that firmware read an address inside `OUTPUT_READ_WINDOW`. For a legal read, the Output block must return a 32-bit word. |
| `out_window_word_idx[5:0]` | Address Decoder/APB -> Output | Output Result Interface | 32-bit word index based at `0x400`. If `local_addr=0x400`, the index is 0; if `local_addr=0x404`, the index is 1. |
| `out_window_rdata[31:0]` | Output -> Address Decoder/APB | APB read path | Output word returned to firmware. It is transferred to APB `PRDATA[31:0]`. |
| `out_window_ready` | Output -> Address Decoder/APB | APB ready path | Indicates that the Output block can process the read immediately. If 0, APB may insert a wait with `PREADY=0`. |
| `out_window_err` | Output -> Address Decoder/APB/FSM | Error path | Indicates a read with no result or a word index outside the valid range. Reflected into APB `PSLVERR` and `ERROR_CODE`. |
| `out_result_valid` | Output -> RegBank/FSM | RegBank, Main FSM | Indicates that there is a result set firmware can read. Reflected in `STATUS.result_valid` and `OUTPUT_STATUS.result_valid`. |
| `out_busy` | Output -> RegBank | RegBank | Indicates the Output block is internally processing. Used by firmware and debug to observe output path state. |
| `out_count` | Output -> RegBank | RegBank/FSM debug | Number of results accepted by the Output block. Used to check drain/writeback progress. |
| `out_window_words` | Output -> RegBank | RegBank | Number of valid 32-bit words occupied by the current tile result in the output window. Provided to firmware through `OUTPUT_WORDS`. |
| `out_format_id` | Output -> RegBank | RegBank | Output format identifier. Used by firmware to determine how to interpret the result payload. |
| `out_words_per_element` | Output -> RegBank | RegBank | Number of 32-bit words needed to read one output element. Used by firmware to build element-level read loops. |

`out_window_word_idx` is generated from the address read by firmware.  
The Address Decoder treats the access as an output window read if `local_addr` is in the `0x400-0x4FF` range and the read is 32-bit aligned.  
Then it sends the value equivalent to `out_window_word_idx = (local_addr - 12'h400) >> 2` to the Output block.

If `out_result_valid=1` and `out_window_word_idx < out_window_words`, the Output block returns the corresponding word.  
For a normally prepared read, the target is to keep `out_window_ready=1` so it can be read without APB wait.  
If the Output block cannot provide data immediately because of internal read latency, it can wait using `out_window_ready=0`.

### 8.4 Output Read Error Conditions

Output read is an error in the following cases.

- `OUTPUT_READ_WINDOW` is read while `out_result_valid=0`
- `out_window_word_idx >= out_window_words`
- APB tries to complete a read while `out_window_ready=0`
- The Output block does not consider the requested word index valid

`out_window_ready=0` does not always have to be an error.  
If the Output block is only temporarily not ready, it can be handled as an APB wait state.  
However, if no result exists at all or the word index is outside the valid range, waiting will not fix the access, so completing quickly with `PSLVERR=1` is clearer.

Output read error conditions are needed so firmware does not accidentally believe it has read a correct result.  
For example, if `out_result_valid=0` but the output window returns an arbitrary value, firmware may use that value as a normal result.  
This would be a silent failure, so cases with no readable result or an out-of-range word index must be exposed clearly as errors.

### 8.5 What the Output Owner Can Decide Freely

The Output owner can decide the following internally.

- Result payload width
- Result storage structure
- Result index mapping
- Result format
- Method for splitting one result into multiple 32-bit words
- Output read latency
- Internal buffering method

However, the top-level signal contract defined above must be respected.  
In other words, firmware must always be able to directly read results in 32-bit word units through `OUTPUT_READ_WINDOW`.

This master reference requires output as a direct memory-mapped read window at `0x400-0x4FF`.  
Therefore, regardless of the internal storage structure used by the Output block, it must respond to APB read requests to this window through `out_window_rdata[31:0]`, `out_window_ready`, and `out_window_err`.

The Output owner's freedom is freedom over the internal implementation.  
If the firmware-visible memory map is changed arbitrarily, the connection to APB/Decoder/RegBank/HAL breaks.  
Therefore, the Output owner can decide internal result width, storage structure, and word splitting method, but externally it must present a consistent contract through `OUTPUT_READ_WINDOW`, `out_window_words`, `out_words_per_element`, and `out_format_id`.


## 9. Detailed Description by Module

This section explains why each module exists, what it receives as input, and what it sends as output.  
When team members implement their assigned modules, they should check this section first.

In this document, a boundary signal does not mean only a SoC top-level port. Even inside the subsystem, if a signal crosses from module A to module B, it is a boundary signal. Boundary signals must be agreed on between team members, so they are defined in tables with `Signal Name`, `Direction`, `Peer Module`, and `Meaning or Purpose`.  
In contrast, pipeline registers used only inside one module, PE-internal forwarding signals, and MAC-internal accumulator connection signals are not named by this document. Such items are described in natural language under "Implementation Notes", and the actual signal names and structures are defined by each owner in their internal spec.

### 9.1 APB Slave I/F

#### Why This Module Exists

The APB Slave I/F is the boundary between the SoC APB bus and our internal logic.  
The CPU accesses our subsystem through the APB protocol, but if internal blocks such as the RegBank or FSM directly handle APB signals, every module must understand bus timing.  
That makes implementation and verification difficult.

The APB Slave I/F converts the APB protocol into simpler internal bus signals that are easier to use inside the subsystem.

This block must be well-defined so the downstream modules can remain simple.  
The RegBank does not need to interpret combinations of `PSEL`, `PENABLE`, and `PWRITE`; it only needs to look at `bus_wena` and `bus_rena`.  
The Decoder does not need to understand the full APB transaction timing; it can select the target register using only `local_addr` and read/write enables.  
In other words, the APB Slave I/F prevents the complexity of the external bus protocol from spreading into the subsystem.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `clk_in` or `PCLK` | Input | SoC wrapper | Subsystem clock. The APB I/F samples APB transactions and creates internal bus events using this clock. |
| `reset_int` or `PRESETn` | Input | SoC wrapper | Subsystem reset. The Didactic-SoC repo student subsystem convention treats this as active-low reset. That is, `reset_int=0` means reset asserted, and `reset_int=1` means reset released/run. Even if the final wrapper uses a name such as `PRESETn`, the internal reset meaning should follow this polarity. |
| `ss_ctrl_i[7:0]` | Input | SoC controller/wrapper | Control bus delivered from the SoC controller to the subsystem. Bit 0 means standard clock enable and bit 1 means fast clock enable. This is upper-level control and is different from the accelerator-internal `CONTROL` register, so the roles must not be mixed. |
| `PSEL` | Input | SoC APB | Indicates that this APB slave is selected. Used with `PENABLE` to determine APB setup/access phase. |
| `PENABLE` | Input | SoC APB | Indicates the APB access phase. This signal is needed to distinguish setup phase from the actual response phase. |
| `PWRITE` | Input | SoC APB | 1 means write, 0 means read. This becomes the basis for creating internal `bus_wena` or `bus_rena`. |
| `PADDR` | Input | SoC APB | APB address accessed by the CPU. Internal RTL uses only `PADDR[11:0]` as the local offset. |
| `PWDATA[31:0]` | Input | SoC APB | APB write payload. Delivered as register write data or raw `ROW_INJECT_DATA`. |
| `PSTRB[3:0]` | Input | SoC APB | APB byte strobe. Our contract uses 32-bit full-word access, so it does not require an internal byte-write policy. |
| `PRDATA[31:0]` | Output | SoC APB | APB read result. The selected `bus_rdata` from the RegBank or Output read path is driven with APB timing. |
| `PREADY` | Output | SoC APB | Tells whether the APB transaction can complete. The normal path targets 1, but wait can be inserted when the internal target cannot accept/serve the access. |
| `PSLVERR` | Output | SoC APB | Indicates that the APB transaction completed with an error. Used for invalid address, alignment violation, state violation, and similar cases. |
| `local_addr[11:0]` | Output | Address Decoder | 4 KiB local offset extracted from `PADDR[11:0]`. Keeps the internal decode unchanged even if the subsystem slot changes. |
| `bus_wdata[31:0]` | Output | Address Decoder, RegBank, Frontend | APB write data shared with internal modules. |
| `bus_wena` | Output | Address Decoder | Marks the cycle where a write transaction is internally accepted. Prevents the same write from being processed multiple times. |
| `bus_rena` | Output | Address Decoder | Marks the cycle where a read transaction is internally accepted. Used by the Decoder to select the read target mux. |
| `bus_rdata[31:0]` | Input | Address Decoder/RegBank path | Read data selected internally. The APB I/F drives this value onto `PRDATA`. |
| `bus_ready` | Input | Address Decoder/target path | Indicates whether the internal target can complete the transaction. Reflected into `PREADY`. |
| `bus_err` | Input | Address Decoder/target path | Indicates whether the internal target judged the access as an error. Reflected into `PSLVERR`. |

#### Main Meaning

`bus_wena` means the APB write transaction is valid internally.  
`bus_rena` means the APB read transaction is valid internally.  
These signals should occur only once after the APB setup/access phase is interpreted.

`PREADY` tells the APB master whether the transaction is complete.  
If an internal block is not ready, the transaction can be held with `PREADY=0`.

`PSLVERR` means that the APB access was an error.  
Unaligned access, invalid address, and invalid state access can connect to this.

`PRDATA` is the 32-bit value returned to firmware during a read access.  
This may be RegBank read data or `OUTPUT_READ_WINDOW` data from the Output block.  
The APB Slave I/F should not directly compute the internal read source. Its role is to drive the `bus_rdata` selected by the Decoder/RegBank/Output path with correct APB timing.

`PREADY` and `PSLVERR` must be distinguished.  
`PREADY=0` means the transaction has not finished yet, while `PSLVERR=1` means the transaction has finished but ended with an error.  
Temporary internal not-ready conditions can be handled with wait states, while invalid address or invalid state access should end quickly with an error.

#### Implementation Notes

The APB Slave I/F does not interpret the meaning of data.  
For example, whether a write to `0x100` is weight or activation is judged by the FSM and Decoder.  
The APB I/F focuses on converting bus transactions accurately into internal signals.

If the APB I/F starts interpreting data meaning, block boundaries become unclear.  
For example, if the APB I/F directly checks precision or FSM phase and creates the row injection mode, the responsibilities of the Decoder and FSM get mixed into the APB I/F.  
Then, when the protocol changes or a testbench is created later, it becomes unclear which block should be verified as the reference.  
Therefore, the APB I/F should focus on bus timing and APB responses, while address meaning and state legality should be handled by the Decoder/FSM.

### 9.2 Address Decoder

#### Why This Module Exists

The Address Decoder looks at `local_addr` and decides what the access targets.

The same APB write has different meanings depending on the address.

- A write to `0x000` may be a control command.
- A write to `0x008` may be a precision configuration.
- A write to `0x100` may be a row injection data push.

This distinction must be handled in one place so the RegBank, FSM, and Frontend share the same address interpretation.

Without a Decoder, each module may compare addresses in its own way.  
Then one module might treat the `0x100` range as the row injection window, while another module might treat it as reserved.  
The Address Decoder is the single reference point for the local memory map, so every APB access must pass through its interpretation.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `local_addr[11:0]` | Input | APB Slave I/F | 4 KiB local offset. The Decoder does not look at the absolute base address and decodes only this value. |
| `bus_wena` | Input | APB Slave I/F | Indicates that a write access must be processed in the current cycle. |
| `bus_rena` | Input | APB Slave I/F | Indicates that a read access must be processed in the current cycle. |
| `bus_wdata[31:0]` | Input | APB Slave I/F | Write payload. The Decoder does not store it; it forwards it to the target module. |
| `phase` | Input | Main Control FSM | Current FSM state. Needed because the same address can be legal or illegal depending on state. |
| `frontend_ready` | Input | Row Injection FIFO/Staging path | Indicates whether the row injection path can accept a new token. If not, it can lead to an APB wait. |
| `out_window_ready` | Input | Output Result Interface | Indicates whether an output window read request can be processed immediately. If not ready, the APB read can be waited. |
| `out_window_rdata[31:0]` | Input | Output Result Interface | Output window read data. Selected as `bus_rdata` for reads in `0x400-0x4FF`. |
| `out_window_err` | Input | Output Result Interface | Indicates an illegal output window read. Used for reads with no result or reads outside the valid word range. |
| `reg_sel` | Output | RegBank | Marks an access to the `0x000-0x0FF` register region. |
| `reg_we` | Output | RegBank | Legal register write enable. Illegal writes, such as config writes while busy, must not be passed through as normal writes. |
| `reg_re` | Output | RegBank | Legal register read enable. Used by the RegBank read mux. |
| `reg_addr[7:0]` | Output | RegBank | Byte offset within the register region. Used by the RegBank to select `CONTROL`, `STATUS`, and other registers. |
| `reg_wdata[31:0]` | Output | RegBank | Register write data. |
| `row_inject_we` | Output | Precision Row Injection Frontend | Legal write push to the `ROW_INJECT_DATA` window. This is the starting point for actual row token creation. |
| `row_inject_region_offset[7:0]` | Output | Precision Row Injection Frontend | Offset within the injection window. Can be used by row or word index generation policy. |
| `out_window_re` | Output | Output Result Interface | Indicates that an `OUTPUT_READ_WINDOW` read occurred. Triggers a direct read request to the Output block. |
| `out_window_word_idx[5:0]` | Output | Output Result Interface | 32-bit output word index based at `0x400`. If `local_addr=0x400`, the index is 0; if `0x404`, the index is 1. |
| `illegal_access` | Output | Main Control FSM/RegBank | Indicates that an address, alignment, or state policy was violated. Basis for sticky `ERROR` and `ERROR_CODE`. |
| `bus_rdata[31:0]` | Output | APB Slave I/F | Selected APB read data from the RegBank or Output read path. |
| `bus_ready` | Output | APB Slave I/F | Indicates whether the selected target can complete the access. |
| `bus_err` | Output | APB Slave I/F | Indicates whether the selected access is an error. |

#### Main Meaning

The Address Decoder is not only a simple address comparison block.  
It must also judge whether the access is legal in the current FSM state.

For example, a `ROW_INJECT_DATA` write may have a correct address, but it must not be accepted in `IDLE_CFG` because data push is not allowed yet.  
Therefore, the Decoder must judge address legality and state legality together.

Separating `decode_err`, `unaligned_err`, and `illegal_access_err` clarifies the error cause.  
Access to an unassigned address, a 32-bit alignment violation, and an access not allowed in the current FSM state are all errors, but their causes are different.  
This difference should propagate to `ERROR_CODE` so firmware and testbenches know what to fix.

#### Implementation Notes

The Decoder does not compare the absolute base address.  
It uses only the `PADDR[11:0]` local offset already received from the APB I/F.

The Decoder is not a storage block.  
It does not store register values. It creates select signals that decide which target receives the current access.  
Therefore, storing the `CONFIG` value is the RegBank's responsibility, and unpacking the `ROW_INJECT_DATA` payload is the Frontend's responsibility.  
The Decoder focuses on deciding "what kind of access is this?" and "is it allowed now?"

### 9.3 RegBank

#### Why This Module Exists

The RegBank stores firmware-visible register values and exposes hardware status so firmware can read it.

Without the RegBank, control bits, config fields, and status fields would be scattered across several modules.  
Then it would be difficult to track what firmware reads and writes, and reset values or write policies would be unclear.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `reg_we`, `reg_re` | Input | Address Decoder | Indicates that a legal register write/read access occurred. The RegBank causes register side effects only when these signals are present. |
| `reg_addr[7:0]` | Input | Address Decoder | Register offset. Used to select `CONTROL`, `STATUS`, `CONFIG`, `OUTPUT_*`, and other registers. |
| `reg_wdata[31:0]` | Input | Address Decoder | 32-bit register payload written by firmware. |
| `phase`, `busy`, `done`, `error`, `phase_detail` | Input | Main Control FSM | Current execution state. Used for `STATUS` reads, PMOD debug, and state-based access protection. |
| `weight_count`, `input_count`, `drain_count` | Input | Main Control FSM | Current tile progress. Needed by firmware and testbenches to check how far execution has progressed. |
| `out_count` | Input | Output Result Interface | Number of results accepted by the Output block. Shows output path progress. |
| `out_result_valid`, `out_busy` | Input | Output Result Interface | Indicates whether a readable result exists and whether the Output block is internally processing. |
| `out_window_words` | Input | Output Result Interface | Number of valid 32-bit words in the current output window. Used for `OUTPUT_WORDS` read. |
| `out_format_id`, `out_words_per_element` | Input | Output Result Interface | Output format metadata. Used by firmware to interpret output window read words. |
| `irq_status` | Input | IRQ Logic | Pending interrupt state. Used for `IRQ_STATUS` read. |
| `pmod_0_gpi[3:0]`, `pmod_1_gpi[3:0]` | Input | PMOD Debug/SoC PMOD | Official SoC PMOD input ports. The RegBank gathers these into `SA_PMOD_GPI` readback so firmware can check current external pin state. |
| `reg_rdata[31:0]` | Output | Address Decoder/APB read path | Selected register read data. |
| `cfg_act_prec[1:0]`, `cfg_wgt_prec[1:0]` | Output | Main Control FSM, Frontend | Activation/weight precision settings. Must be fixed before `start`. |
| `cfg_signed_twos_complement` | Output | Main Control FSM, Frontend/SA path | Fixed indicator that operands are interpreted as signed two's complement. |
| `tile_m`, `tile_n`, `tile_k` | Output | Main Control FSM, Scheduler/SA policy | Current hardware tile dimensions. These are the current tile size, not the full matrix size. |
| `ctrl_start_pulse`, `ctrl_soft_reset_pulse` | Output | Main Control FSM | One-cycle pulses converted from firmware command bits. |
| `ctrl_clear_done_pulse`, `ctrl_clear_error_pulse` | Output | Main Control FSM/IRQ Logic | Command pulses used to clear sticky done/error state. |
| `irq_enable` | Output | IRQ Logic | Local done/error interrupt enable. Gated together with SoC-level enable. |
| `pmod_debug_en`, `pmod_debug_page` | Output | PMOD Debug | PMOD debug output enable and page selection. |

#### Main Meaning

The RegBank is the state storage between firmware and hardware.  
Settings written by firmware are stored in the RegBank, and the FSM or Frontend uses these values.

Conversely, status generated by hardware is visible to firmware through the RegBank.  
For example, when the FSM reaches `DONE`, `STATUS.done` appears as 1.

Even if the RegBank appears to have many fields, firmware does not have to handle every field manually every time.  
Once the HAL is created, firmware applications can use functions such as `sa_config()`, `sa_start()`, `sa_push_weight()`, `sa_push_activation()`, and `sa_read_output()`.  
The many RegBank fields are the low-level contract that allows the HAL and testbench to handle hardware state precisely.

To prevent RegBank complexity from growing uncontrollably, each field's purpose must be clearly separated.  
`CONFIG` and `DIM` are pre-execution settings, `CONTROL` is commands, `STATUS` and counters are observation, `OUTPUT_*` is read-related information, `IRQ_*` is interrupt management, and `PMOD_*` is debug.  
With this role separation, even if the number of registers is somewhat large, the control flow becomes clearer.

#### Implementation Notes

The RegBank must have a clear write policy.

- `CONFIG`, `DIM`: writes allowed only in `IDLE_CFG`
- `CONTROL`: handled as command bits
- `IRQ_STATUS`: sticky W1C
- `OUTPUT_STATUS`, `OUTPUT_WORDS`: used to check output window readability and number of words to read
- RO registers: decide whether firmware writes are ignored or treated as errors

Initial reset values must also be clear.  
In particular, `done`, `error`, `busy`, `phase`, and `irq_status` must be predictable after reset.

The RegBank implementation must strictly separate read-only fields from writable fields.  
For example, if firmware writes 0 to `STATUS.busy`, the actual FSM busy state must not become 0.  
`STATUS.busy` is a field that shows firmware the state produced by the FSM, so it must not change due to firmware writes.  
In contrast, `CONFIG.act_prec` is a setting value written by firmware, so the RegBank must store it and provide it to the Frontend/FSM.

### 9.4 Main Control FSM

#### Why This Module Exists

The Main Control FSM determines the execution order of the whole accelerator.

APB/RegBank receive firmware commands, but the FSM must decide when to receive weights, when to receive activations, and when to drain results.

Without an FSM, several blocks may operate using different standards.  
For example, the Scheduler may wait for activations while the RegBank still thinks the system is in the config phase.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `ctrl_start_pulse`, `ctrl_soft_reset_pulse` | Input | RegBank | Firmware command events. Starting point for FSM state transitions or full clear. |
| `ctrl_clear_done_pulse`, `ctrl_clear_error_pulse` | Input | RegBank | Commands to clear sticky `done`/`error` state. |
| `cfg_act_prec`, `cfg_wgt_prec` | Input | RegBank | Precision settings. They must not change after start while busy. |
| `tile_m`, `tile_n`, `tile_k` | Input | RegBank | Dimensions of this tile. Used to compute expected weight/input/result counts. |
| `illegal_access` | Input | Address Decoder | Indicates that an invalid register/data window access occurred. The FSM records this as `ERROR`. |
| accepted write count | Input | Frontend/Scheduler | Basis for increasing `WEIGHT_COUNT` and `INPUT_COUNT`. Counted in accepted 32-bit `ROW_INJECT_DATA` write words. |
| `weight_map_done` | Input | Scheduler/SA Core | Indicates that required weight mapping is complete. Condition for moving to `ACT_STREAM_COMPUTE`. |
| `activation_input_done` | Input | Scheduler/SA Core | Indicates that all required activation input has entered the SA. Condition for moving to `DRAIN_WRITEBACK`. |
| `sa_pipeline_empty` | Input | Systolic Array Core | Indicates that there are no pending results left in the internal pipeline. Used to determine `DONE`. |
| `result_valid`, `result_ready`, `result_last` | Input | SA Core, Output Result Interface | Used to judge result transfer accept and the last result. Counts must increase based on `result_valid && result_ready`. |
| `phase`, `busy`, `done`, `error`, `phase_detail` | Output | RegBank, Decoder, PMOD/IRQ path | Basis for firmware-visible status and state-specific legal access decisions. |
| `row_inject_mode` | Output | Frontend, Scheduler | `0` means weight mapping token, `1` means activation stream token. This is generated from FSM phase, not from a firmware register. |
| `sa_weight_map_en`, `sa_act_stream_en` | Output | Scheduler, SA Core | Tells whether the current row token should be handled as weight mapping or activation streaming. |
| `sa_compute_en`, `sa_drain_en`, `sa_clear` | Output | Systolic Array Core | Allows compute, drain, and clear behavior. Does not force the internal SA implementation method. |
| `irq_done_event`, `irq_error_event` | Output | IRQ Logic | Pulses that notify IRQ logic of `DONE` or `ERROR` events. |
| `weight_count`, `input_count`, `drain_count`, `error_code` | Output | RegBank | Provides progress and error cause for firmware and testbenches. |

#### Main Meaning

The FSM does not compute data itself.  
It only decides which block is active in the current phase, which accesses are legal, and when to move to the next phase.

`row_inject_mode` is not a register written by firmware.  
It is generated automatically from the FSM phase.

- `WEIGHT_MAP`: `row_inject_mode=0`
- `ACT_STREAM_COMPUTE`: `row_inject_mode=1`

FSM output signals tell each block "what role should be performed now".  
`sa_weight_map_en` means the Scheduler/SA should interpret the incoming token as weight mapping. `sa_act_stream_en` means it should be interpreted as activation streaming.  
`sa_compute_en` enables MAC/update behavior, and `sa_drain_en` tells the SA that it is allowed to send remaining results to the result path.  
These signals allow each block to decide its behavior without directly interpreting the current phase.

#### Implementation Notes

There is no need to increase the number of FSM states too much.  
Detailed progress should be shown through counters and `phase_detail`, while the top-level phase remains six states.

Transition conditions must be verifiable in the testbench.  
For example, if the condition "enough weights entered" exists only as implicit internal state, verification is difficult.  
It should be expressed through observable signals such as counts, done flags, or ready/valid accept events.

Because the FSM is the reference for the team's whole control flow, ambiguous transitions will affect other modules as well.  
For example, if the condition for moving from `WEIGHT_MAP` to `ACT_STREAM_COMPUTE` is unclear, firmware cannot know when it should start sending activations.  
Therefore, transition conditions must be expressed and documented through explicit signals such as count, done, empty, last, and valid/ready accept.

### 9.5 Precision Row Injection Frontend

#### Why This Module Exists

The Precision Row Injection Frontend interprets a 32-bit APB word as actual operand elements.

APB data is always 32 bits, but the actual operand precision is one of `INT4`, `INT8`, `INT16`, or `INT32`.  
Therefore, the number of elements and the sign extension method differ depending on precision even for the same 32-bit word.

This processing must be handled in one place so the Scheduler and SA Core do not repeatedly implement precision-specific bit slicing.

Without the Frontend, precision packing rules would be scattered across several places.  
The Scheduler might need to know `INT4` slicing, the PE might again need to know sign extension, and the MAC might directly interpret precision-specific operand widths.  
In that situation, if the packing order changes in one place, other blocks may not follow, causing incorrect results.  
The Frontend gathers APB word interpretation into one place and makes downstream blocks simpler.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `row_inject_we` | Input | Address Decoder | Indicates that a legal `ROW_INJECT_DATA` write occurred. This pulse starts the unpack operation. |
| `row_inject_region_offset[7:0]` | Input | Address Decoder | Offset inside the injection window. Can be used by row or word index generation policy. |
| `row_inject_data[31:0]` or `bus_wdata[31:0]` | Input | Address Decoder/APB write path | Packed 32-bit payload. Split into multiple elements depending on precision. |
| `row_inject_mode` | Input | Main Control FSM | Tells whether the current payload should be interpreted as weight or activation. |
| `cfg_act_prec[1:0]`, `cfg_wgt_prec[1:0]` | Input | RegBank | Used to select unpack precision. The activation or weight precision is chosen depending on mode. |
| `frontend_ready` | Input | FIFO/Staging | Indicates whether the downstream buffer can accept a token. If not, this can propagate to APB wait. |
| `frontend_valid` | Output | FIFO/Staging | Indicates that an unpacked token is valid. |
| `frontend_mode` | Output | FIFO/Staging | Carries whether this token is a weight token or activation token. |
| `frontend_row_idx` | Output | FIFO/Staging | Indicates which logical row this token belongs to. |
| `lane_valid[INJECT_LANES_MAX-1:0]` | Output | FIFO/Staging | Marks which lanes in the current token contain real elements. Prevents padding lanes from entering computation. |
| `lane_data[INJECT_LANES_MAX*32-1:0]` | Output | FIFO/Staging | Signed-extended 32-bit operand payload for each lane. Downstream blocks do not need to slice the original bit width again. |
| `lane_count` | Output | Main Control FSM/debug | Number of valid elements in this APB word. Firmware-visible `WEIGHT_COUNT/INPUT_COUNT` count words, while `lane_count` is used for precision packing debug or expected element checks. |
| `packing_error` | Output | Main Control FSM/RegBank | Indicates a malformed sequence or a packing issue that does not match the dimension. |

#### Main Meaning

The Frontend selects precision based on the current mode.

- Weight token: use `wgt_prec`
- Activation token: use `act_prec`

Then it divides the 32-bit word into elements from the LSB upward and extends each element into a signed 32-bit lane payload.

`frontend_valid` indicates that the token produced by the Frontend is meaningful data.  
`frontend_ready` indicates that the downstream FIFO/Staging can accept that token.  
Only when both are 1 is the Frontend output token considered transferred downstream.  
This rule keeps the APB write count and internal token count consistent.

#### Implementation Notes

In the last word, not every element lane may be valid.  
In that case, `lane_valid` must be generated accurately.

Also, if `CONFIG` changes while busy, the Frontend interpretation changes, so such writes must be blocked by the RegBank/FSM.

The Frontend does not compute the mathematical result.  
That is, it does not perform matrix multiplication and does not create MAC results.  
The Frontend's responsibility is to arrange the packed APB word into signed lane payloads according to precision.  
Keeping this boundary allows Frontend verification to focus on packing, sign extension, lane valid, and ready/valid accept.

### 9.6 Row Injection FIFO/Staging

#### Why This Module Exists

Row Injection FIFO/Staging absorbs timing differences between the Frontend and Scheduler.

The time when APB writes arrive and the time when the SA can receive row data are not always the same.  
Without a FIFO or staging register, the Scheduler would have to receive the data immediately when the Frontend creates it.  
If the Scheduler is temporarily busy, data could be lost.

The FIFO/Staging described here does not mean a large input buffer.  
Our basic direction is not to store the entire activation or weight set in a large external buffer before computation.  
This block is a shallow staging or backpressure protection mechanism for creating the normal no-wait path.  
Depending on the implementation, a depth-1 register slice may be enough. Even if a deeper FIFO is used, its purpose is to absorb momentary ready differences, not to store large input data.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `frontend_valid` | Input | Precision Row Injection Frontend | Indicates that the token provided by the Frontend is valid. |
| `frontend_mode` | Input | Precision Row Injection Frontend | Indicates whether the token means weight or activation. |
| `frontend_row_idx` | Input | Precision Row Injection Frontend | Logical row index of the token. |
| `lane_valid[INJECT_LANES_MAX-1:0]` | Input | Precision Row Injection Frontend | Marks valid lanes in the token. |
| `lane_data[INJECT_LANES_MAX*32-1:0]` | Input | Precision Row Injection Frontend | Token payload. The FIFO preserves this value without reinterpreting it. |
| `row_fifo_ready` | Input | SA Injection Scheduler | Indicates whether the Scheduler can accept a FIFO token. |
| `sa_clear` or reset | Input | Main Control FSM/reset path | Indicates a situation where pending tokens should be removed or initialized. |
| `frontend_ready` | Output | Precision Row Injection Frontend/APB wait path | Indicates whether the FIFO can accept a new token. If 0, upstream must not transfer a token. |
| `row_fifo_valid` | Output | SA Injection Scheduler | Indicates that there is a token to pass to the Scheduler. |
| `row_fifo_mode` | Output | SA Injection Scheduler | Mode of the buffered token. |
| `row_fifo_row_idx` | Output | SA Injection Scheduler | Logical row index of the buffered token. |
| `row_fifo_lane_valid[INJECT_LANES_MAX-1:0]` | Output | SA Injection Scheduler | Valid lane marks of the buffered token. |
| `row_fifo_lane_data[INJECT_LANES_MAX*32-1:0]` | Output | SA Injection Scheduler | Buffered token payload. |
| `row_fifo_empty`, `row_fifo_full` | Output | FSM/Decoder/debug path | FIFO state. Empty/full can be used for `phase_detail`, APB wait, or debug. |

#### Main Meaning

FIFO/Staging does not change the meaning of data.  
It does not turn weight into activation or reinterpret precision.  
It stores the token created by the Frontend in order and passes it to the Scheduler when the Scheduler can receive it.

This block is needed because APB write timing and SA injection timing are not always identical.  
Firmware can write `ROW_INJECT_DATA` at the speed allowed by the APB bus, but the Scheduler may be able to accept tokens only on certain cycles according to SA internal timing.  
FIFO/Staging absorbs this speed difference, reducing APB wait in normal cases and preventing data loss in exceptional cases.

#### Implementation Notes

The owner can decide the depth.  
However, the top-level contract must be maintained.

- If it can accept, `frontend_ready=1`
- If it is full, `frontend_ready=0`
- If there is data to pass to the Scheduler, `row_fifo_valid=1`
- The actual pop occurs on `row_fifo_valid && row_fifo_ready`

The contract can be satisfied with depth 1, and it can also be satisfied with a deeper FIFO.  
What matters is not the depth itself, but that full state is reported upstream with `frontend_ready=0`, and empty state is reported downstream with `row_fifo_valid=0`.  
Therefore, when designing this block, think first of the minimal structure that keeps `ready=1` in normal cases and prevents data loss in exceptional cases, rather than growing it into a buffer that stores the input matrix.  
These two signals must be accurate for the APB wait policy and Scheduler token consumption to connect safely.

### 9.7 SA Injection Scheduler

#### Why This Module Exists

The SA Injection Scheduler delivers row injection data to the SA Core with the timing and row order required by the SA Core.

The Frontend/FIFO creates data in the form of an interpreted row token.  
However, because of internal systolic timing, the SA Core may require data to enter a specific row in a specific cycle.  
The Scheduler handles this timing adjustment.

The Scheduler is needed because the token order produced by the Frontend and the cycle order wanted by the internal SA PEs may not always be the same.  
A systolic array requires data to enter rows and columns with a certain timing relationship so that the correct operation happens at the correct PE.  
The Frontend only unpacks data; the Scheduler decides which cycle and which row the data enters.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `row_fifo_valid` | Input | Row Injection FIFO/Staging | Indicates that the FIFO has a token to transfer. |
| `row_fifo_mode` | Input | Row Injection FIFO/Staging | Indicates whether the FIFO token is for weight mapping or activation streaming. |
| `row_fifo_row_idx` | Input | Row Injection FIFO/Staging | Logical row index of the FIFO token. |
| `row_fifo_lane_valid[INJECT_LANES_MAX-1:0]` | Input | Row Injection FIFO/Staging | Valid lane marks inside the FIFO token. |
| `row_fifo_lane_data[INJECT_LANES_MAX*32-1:0]` | Input | Row Injection FIFO/Staging | FIFO token payload. The Scheduler may adjust timing, but it must not change the meaning of the values. |
| `sa_row_ready` | Input | Systolic Array Core | Indicates whether the SA Core can accept a boundary row token. If 0, the Scheduler must hold the token without losing it. |
| `sa_weight_map_en`, `sa_act_stream_en`, `sa_compute_en`, `sa_drain_en`, `sa_clear` | Input | Main Control FSM | Indicates which scheduling behavior is allowed in the current phase. |
| `row_fifo_ready` | Output | Row Injection FIFO/Staging | Indicates that the Scheduler can consume the FIFO token. |
| `sa_row_valid` | Output | Systolic Array Core | Indicates that the row token provided by the Scheduler to the SA Core is valid. |
| `sa_row_mode` | Output | Systolic Array Core | Indicates the meaning of the SA boundary token. 0 means weight mapping, 1 means activation streaming. |
| `sa_row_idx` | Output | Systolic Array Core | Tells the SA Core which logical row should handle the token. |
| `sa_row_lane_valid[INJECT_LANES_MAX-1:0]` | Output | Systolic Array Core | Valid lane marks inside the SA boundary token. |
| `sa_row_lane_data[INJECT_LANES_MAX*32-1:0]` | Output | Systolic Array Core | Signed lane payload transferred to the SA Core. |
| `weight_map_done` | Output | Main Control FSM | Indicates that required weight token scheduling is complete. Used as an FSM transition condition. |
| `activation_input_done` | Output | Main Control FSM | Indicates that required activation token scheduling is complete. Used as an FSM transition condition. |
| `sched_accept` or progress status | Output | Main Control FSM/RegBank debug | Progress status that can be used for token accept count or `phase_detail`. The owner can decide the name and detailed width. |

#### Main Meaning

The Scheduler can send weight mapping and activation streaming through the same physical row input path.  
However, their mode and timing are different.

- During weight mapping, values must enter PE internal weight locations.
- During activation streaming, activation values flow to perform computation.

This difference must be handled in the contract between the Scheduler and SA Core.

The Scheduler looks at `row_inject_mode` and decides whether to send the same lane data for weight mapping or activation streaming.  
Firmware must not directly determine the mode; the mode must be produced by the FSM phase.  
This keeps the top-level sequence and SA internal injection timing based on the same standard.

#### Implementation Notes

The Scheduler owner can decide the internal skew method, number of delay registers, and row ordering policy.  
However, the completion signals provided to the top level must be clear.

- Weight mapping complete
- Activation input complete
- Status needed for SA pipeline empty or drain completion

Completion signals are very important because they are the basis for FSM transitions.  
If it is ambiguous when `weight_map_done` becomes 1, the FSM may move to activation phase too early or too late.  
Likewise, `activation_input_done` must clearly report that all activation tokens have entered the SA.  
The Scheduler internal implementation is free, but the completion condition seen by the FSM must be provided as a verifiable signal.

The boundary signals passed from Scheduler to SA Core are defined as the `sa_row_*` group.  
These names are the module-to-module interface between Scheduler and SA Core, not PE signal names inside the SA Core.  
How the SA Core sends this row token to PEs, buffers, or internal datapaths is decided by the SA Core owner.

### 9.8 Systolic Array Core

#### Why This Module Exists

The Systolic Array Core is the central block that performs the actual matrix multiplication.

This is the most computation-centered part of the subsystem.  
The APB I/F, Decoder, RegBank, and FSM organize when and what data enters, and the Row Injection path converts data into a form the SA can receive.  
Finally, the actual multiply-accumulate operations and data movement between PEs are performed inside the SA Core.

From the top-level perspective, the SA Core must provide the following functions.

- Receive weight tokens and map them into internal PE weight positions.
- Receive activation tokens and perform computation.
- Send result payloads to the Output block when computation results are produced.
- Report whether the internal pipeline is empty.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `sa_row_valid` | Input | SA Injection Scheduler | Indicates that the row token provided by the Scheduler is valid. |
| `sa_row_mode` | Input | SA Injection Scheduler | Indicates whether the token is for weight mapping or activation streaming. |
| `sa_row_idx` | Input | SA Injection Scheduler | Logical row index of the token. How it is distributed inside the PE array is the SA Core's internal responsibility. |
| `sa_row_lane_valid[INJECT_LANES_MAX-1:0]` | Input | SA Injection Scheduler | Valid lane marks inside the token. Invalid lanes must not be used for computation or weight mapping. |
| `sa_row_lane_data[INJECT_LANES_MAX*32-1:0]` | Input | SA Injection Scheduler | Signed-extended operand lane payload. Whether it means activation or weight is determined by `sa_row_mode` and FSM phase. |
| `sa_weight_map_en`, `sa_act_stream_en`, `sa_compute_en`, `sa_drain_en`, `sa_clear` | Input | Main Control FSM | Indicates what operation the SA Core is allowed to perform now. These are upper-level phase controls and do not dictate the internal SA implementation. |
| `result_ready` | Input | Output Result Interface | Indicates whether the Output block can receive a result. If 0, the SA Core must hold the current result without losing it. |
| `sa_row_ready` | Output | SA Injection Scheduler | Indicates that the SA Core can accept a new row token. This is the Scheduler's token transfer condition. |
| `weight_map_done` | Output | Main Control FSM | Indicates that, from the SA Core perspective, required weight mapping is complete. Can be combined with the Scheduler to create the final done condition. |
| `activation_input_done` | Output | Main Control FSM | Indicates that the SA Core has received all required activation input. |
| `sa_pipeline_empty` | Output | Main Control FSM | Indicates that there are no pending results left inside the internal pipeline. Needed to determine entry into `DONE`. |
| `result_valid` | Output | Output Result Interface | Indicates that the current `result_*` payload is valid. |
| `result_row` | Output | Output Result Interface | Indicates which row of the output tile the result belongs to. |
| `result_col` | Output | Output Result Interface | Indicates which column of the output tile the result belongs to. |
| `result_data[RESULT_W-1:0]` | Output | Output Result Interface | Result payload. Width and internal numeric format are decided by the SA/Output owners and exposed through capability metadata. |
| `result_last` | Output | Output Result Interface/FSM | Indicates the last result of the current tile. Used by the FSM to determine drain completion. |

#### Main Meaning

The SA Core does not connect output results directly to APB.  
The SA Core sends results to the Output block, and the Output block and RegBank handle the firmware read protocol.

This separation is needed so the SA Core can focus on computation.  
If the SA Core directly handles APB read timing, output word selection, and output format metadata, the compute block becomes tightly coupled to the bus protocol.

For the same reason, the SA Core does not directly handle firmware-visible registers.  
The SA Core does not read `CONFIG`, `DIM`, or `phase` directly from APB. Instead, it receives enable signals and row tokens organized by the FSM/Scheduler.  
This allows the SA Core owner to focus on weight mapping, activation flow, and PE internal result generation rather than APB protocol.

The `sa_row_*` signals are the boundary contract between Scheduler and SA Core.  
These signals do not mean PE port names inside the SA Core.  
How the SA Core distributes row tokens to the PE array, how it handles weight stationary mapping, and how it forwards activations are SA Core internal implementation responsibilities.

#### Implementation Notes

The SA Core owner decides the internal PE structure.  
However, the following top-level contract must be satisfied.

- Assert `result_valid=1` only when the result payload is valid.
- Do not lose the result if the Output block drives `result_ready=0`.
- Assert `result_last=1` on the final result.
- Safely initialize internal progress state when `sa_clear` is asserted.

`sa_pipeline_empty` is a status needed by the FSM to judge whether drain has finished.  
Even if all activation input has entered, that does not necessarily mean all results have immediately come out.  
The SA Core must report when internal pipeline computation has finished and no more results will appear, so the FSM can safely move to `DONE`.

### 9.9 Processing Element (PE, Including MAC Behavior)

#### Why This Module Exists

The Processing Element is the basic compute unit inside the Systolic Array that stores and updates computation state.  
From the top-level perspective, a PE does not need to know APB or firmware directly. A PE receives weight/activation operands delivered by SA Core internal routing, performs internal multiply-accumulate behavior, or creates values to pass to the next location.

PEs are needed because a systolic array consists of many small compute units connected in a regular structure.  
Each PE stores the weight state needed at its own position and performs multiply-accumulate updates with incoming activations, or forwards data to the next location.  
This document does not separate MAC behavior into a separate top-level contract from PE behavior. In actual RTL, the MAC may be placed directly inside the PE, or the PE may instantiate a separate MAC submodule. Either method does not affect top-level integration as long as the SA Core external boundary is maintained.

The reason this document explains PE behavior is not to fix PE internal signal names at the top level.  
The PE belongs to the SA Core internal implementation area. Therefore, the actual RTL signal names, forwarding direction, and local storage structure are decided by the PE/SA Core owners.

The owner can decide exactly how weight stationary behavior is implemented inside the PE, which direction activations are forwarded, and whether the accumulator is placed inside the PE or elsewhere.  
However, from the outside, the PE must be able to receive and store weights during the weight mapping phase, receive operands and perform multiply-accumulate updates during the activation compute phase, and send results to the defined SA Core result path.

#### Information to Consider During Implementation

The PE can freely choose internal signal names and structure, but it must consider the following information and behavior.

- Because the method is weight stationary, weight information entering during the weight mapping phase must be stored in an appropriate PE or SA Core internal location.
- During activation streaming, incoming activation operands must be used with the correct PE timing.
- Activation forwarding direction, forwarding delay, and number of internal pipeline stages are decided by the PE/SA Core owners.
- The PE must be able to distinguish cycles where operands are valid from cycles where internal computation actually executes.
- After a new tile, clear, or reset, old tile weights, valid states, and partial results must not remain. A clear policy is needed.
- The PE/SA Core owners decide when to perform multiply-accumulate updates, where the accumulator is placed, and how partial results are delivered.
- Results created by a PE or PE group must ultimately be collectable into the SA Core `result_valid/result_ready/result_row/result_col/result_data/result_last` boundary interface.
- All operands must be interpreted as signed two's complement.
- The PE must be able to handle signed operands entering under all `INT4`, `INT8`, `INT16`, and `INT32` combinations.

A result created by a PE does not necessarily go directly to the Output block.  
Usually, the SA Core gathers results from several PEs and converts them into the `result_valid/result_ready/result_row/result_col/result_data/result_last` interface with row/column position and last-result information.

Therefore, the PE owner does not need to directly worry about the firmware-visible output format.  
The PE only needs to provide its result or partial result according to the SA Core internal contract.  
Output format, APB read word selection, and format metadata are responsibilities of the Output block and RegBank.

#### Implementation Notes

The PE owner does not have to implement signal names from the top-level document literally.  
Required internal state, valid management, forwarding, and result collection are defined in the SA Core internal spec.  
However, the boundary contract leaving the SA Core must be respected. That is, the SA Core must process the row token stream received from the Scheduler and provide the defined result stream to the Output block.

PE internal numeric policy must not be mixed directly with top-level `ERROR`.  
`ERROR` is for APB/control sequence violations, and PE internal arithmetic policy should be organized separately by the SA Core/PE owners.

The PE implementation must internally manage operand validity, accumulation update timing, pipeline latency, clear/reset handling, and result valid timing.  
These items are necessary, but the top-level document does not force specific signal names for them.

### 9.10 Output Result Interface

#### Why This Module Exists

The Output Result Interface is the boundary between the SA Core and the firmware read path.

The SA Core creates computation results as internal result payloads.  
Firmware can read only 32-bit words through APB.  
Because these two forms may not be the same, the Output block performs conversion, storage, and direct read window provisioning between them.

Without this block, the SA Core would have to directly handle the APB read protocol.  
Then the timing of computation result generation would become tightly coupled to firmware read timing, and changing the internal SA Core result representation could also change the APB memory map.  
The Output Result Interface separates the responsibility of providing computation results in a firmware-readable form from the SA Core.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `result_valid` | Input | Systolic Array Core | Indicates that the result payload provided by the SA Core is valid. |
| `result_row` | Input | Systolic Array Core | Output tile row index of the incoming result. Can be used to calculate placement inside the output window. |
| `result_col` | Input | Systolic Array Core | Output tile column index of the incoming result. Can be used to calculate placement inside the output window. |
| `result_data[RESULT_W-1:0]` | Input | Systolic Array Core | Incoming result payload. The Output block stores it or converts it into the readback format according to internal policy. |
| `result_last` | Input | Systolic Array Core | Last-result marker for the current tile. Can be used to determine result set validity. |
| `out_window_re` | Input | Address Decoder/APB read path | Indicates that firmware read `OUTPUT_READ_WINDOW`. |
| `out_window_word_idx[5:0]` | Input | Address Decoder/APB read path | 32-bit output word index based at `0x400`. The Output block returns the word corresponding to this index. |
| `result_ready` | Output | Systolic Array Core/Main FSM | Indicates that the Output block can accept a new result. If 0, the SA Core must preserve the result. |
| `out_window_ready` | Output | Address Decoder/APB read path | Indicates that the output window read request can be processed. If 0, APB wait may be needed. |
| `out_window_rdata[31:0]` | Output | Address Decoder/APB read path | Selected output window word returned to firmware. |
| `out_window_err` | Output | Address Decoder/APB error path | Indicates an output window read with no result or outside the valid word range. |
| `out_result_valid` | Output | RegBank/Main FSM | Indicates that there is a result set firmware can read. |
| `out_busy` | Output | RegBank | Indicates that the Output block is internally processing. |
| `out_count` | Output | RegBank/Main FSM | Count of results accepted by the Output block. |
| `out_window_words` | Output | RegBank | Number of valid 32-bit words occupied by the current tile result in the output window. |
| `out_format_id` | Output | RegBank | Output format identifier. Used by firmware to check result interpretation. |
| `out_words_per_element` | Output | RegBank | Number of 32-bit words needed to read one element. Used by firmware to build element-level loops. |

#### Main Meaning

The Output block has both a result accept path and a firmware direct read path.  
The result accept path receives results from the SA Core, while the direct read path returns 32-bit words when the CPU reads the `0x400-0x4FF` window.

The top-level contract requires the following.

- Provide `result_ready` accurately so SA results are not lost.
- When firmware reads `OUTPUT_READ_WINDOW`, provide the 32-bit word corresponding to `out_window_word_idx`.
- Provide status/error when there is no result to read.
- Provide format information and valid word count so firmware can check how to interpret the output.

`out_format_id`, `out_words_per_element`, and `out_window_words` are metadata needed by firmware to interpret output.  
Because the top level does not fix the result format, firmware must use this information to know how many words to read from the output window and how those words form elements.  
The Output block may choose its internal format freely, but it must provide information that allows firmware to identify that format.

#### Implementation Notes

The Output block internal storage method is free.  
However, the firmware-visible read protocol is fixed.

Firmware does not know the internal storage structure.  
It only reads sequential addresses of the form `SS_BASE + 0x400 + word_index * 4`, and the Output block must provide the corresponding 32-bit word.

In a cycle where the Output block asserts `result_ready=1`, it must actually be able to receive the result.  
Likewise, for an output window read with `out_window_ready=1` and `out_window_err=0`, `out_window_rdata[31:0]` must be a valid value that can be returned to firmware.  
These two conditions prevent data loss or incorrect reads on both the result write path and firmware read path.

The baseline policy does not generate interrupts every time part of the output becomes filled.  
The Output block marks `out_result_valid=1` after accepting the whole tile result, and the FSM uses `DONE` and done IRQ to notify firmware when the output window is readable.

### 9.11 IRQ Logic

#### Why This Module Exists

IRQ Logic allows firmware to know completion or error events without relying only on polling.

Polling requires firmware to keep reading `STATUS`.  
With IRQ, hardware can notify the CPU when an event occurs.

IRQ is not only a performance feature; it also simplifies firmware structure.  
If the CPU keeps reading `STATUS` while the accelerator performs a long job, the software flow stays busy.  
With IRQ, the CPU can do other work and then check `IRQ_STATUS` and `STATUS` in the handler when a done or error event occurs.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `irq_done_event` | Input | Main Control FSM | Indicates entry into `DONE` or occurrence of a done event. |
| `irq_error_event` | Input | Main Control FSM | Indicates entry into `ERROR` or occurrence of an error event. |
| `irq_enable` | Input | RegBank | Local interrupt enable. Done/error interrupts can be enabled individually. |
| `irq_status_clear` | Input | RegBank | Clears pending IRQ status through firmware W1C write. |
| `irq_en_i` | Input | SoC wrapper | SoC-level interrupt enable. Gates `irq_o` together with local enable. |
| `irq_status` | Output | RegBank | Sticky pending interrupt state. Allows firmware to identify the cause even if the pulse is missed. |
| `irq_o` | Output | SoC wrapper | One-cycle interrupt pulse sent to the CPU. |

#### Main Meaning

`IRQ_STATUS` is sticky state.  
`irq_o` is a pulse emitted in the cycle where the event occurs.

Sticky state is needed because the `irq_o` pulse is short.  
Even if the CPU or firmware cannot read the state in the exact cycle where the pulse occurs, `IRQ_STATUS` remains so the interrupt cause can be checked later.  
Therefore, `irq_o` should be understood as the notification signal, and `IRQ_STATUS` as the cause record.

The actual interrupt output must satisfy:

- The corresponding event occurred.
- The local `IRQ_ENABLE` bit is set.
- The SoC `irq_en_i` is set.

#### Implementation Notes

`IRQ_STATUS` and `irq_o` must be distinguished.  
`IRQ_STATUS` is state that remains until firmware clears it, while `irq_o` is an event pulse that notifies the CPU.

IRQ Logic must consider both SoC-level `irq_en_i` and local `IRQ_ENABLE`.  
Even if local enable is set, `irq_o` must not be driven if the SoC has not enabled that subsystem interrupt.  
Conversely, even if `irq_o` is gated and does not go out, firmware must be able to see the local event record, so the `IRQ_STATUS` set policy must be clearly implemented.

### 9.12 PMOD Debug

#### Why This Module Exists

PMOD Debug is a function for observing part of the internal state on external pins during FPGA bring-up or experiments.

PMOD is not an essential compute path.  
However, because it is included in the project requirements and SoC interface, it is implemented as a top-level contract.

PMOD is not the normal data input/output path of the accelerator.  
Firmware data, weights, activations, and output results move through APB registers and the row injection/output read protocol.  
PMOD should be considered only as a separate debug path for observing internal state.

#### Boundary Signals

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `pmod_debug_en` | Input | RegBank | Decides whether PMOD debug output is driven. If 0, pins are kept input/tristate. |
| `pmod_debug_page` | Input | RegBank | Selects which debug signal group is shown through the limited PMOD pins. |
| `phase`, `busy`, `done`, `error` | Input | Main Control FSM | Control status that can be used for the basic status debug page. |
| `weight_count`, `input_count`, `drain_count`, `out_count` | Input | FSM/Output/RegBank path | Progress information that can be used for a counter debug page. |
| `out_result_valid`, `out_busy` | Input | Output Result Interface | Information that can be used for an output status debug page. |
| `pmod_0_gpi[3:0]`, `pmod_1_gpi[3:0]` | Input | SoC PMOD pins | Two official 4-bit PMOD input ports defined by the SoC documentation. Relayed into the `SA_PMOD_GPI` register. |
| `pmod_0_gpo[3:0]`, `pmod_1_gpo[3:0]` | Output | SoC PMOD pins | Selected 8-bit debug page split into two 4-bit PMOD output ports. |
| `pmod_0_gpio_oe[3:0]`, `pmod_1_gpio_oe[3:0]` | Output | SoC PMOD pins | PMOD output enable. In this SoC convention, 0 means drive and 1 means input/tristate. |
| `SA_PMOD_GPI` readback value | Output | RegBank | Value provided so firmware can check PMOD input state. |

#### Main Meaning

If `debug_en=0`, PMOD pins are not driven.  
If `debug_en=1`, the selected 8-bit debug page is output through `pmod_0_gpo[3:0]` and `pmod_1_gpo[3:0]`.

If the final wrapper uses a 16-bit PMOD GPIO bus, connect the 8-bit logical debug payload formed by the two 4-bit outputs to the lower 8 bits.  
Unless the upper 8 bits are used for debug, it is safer not to drive them. In that case, drive the upper 8-bit outputs to 0 and set output enable so they behave as input/tristate.

`debug_page` is needed because the number of PMOD pins is limited.  
We cannot send every internal debug signal to pins at the same time, so the page selects only the group of signals currently being observed.  
For example, one page can show FSM state and busy/done/error, while another page can show lower bits of counters.

Output enable polarity is matched as follows.

```text
pmod_0_gpio_oe = debug_en ? 4'h0 : 4'hF
pmod_1_gpio_oe = debug_en ? 4'h0 : 4'hF
```

#### Implementation Notes

Connecting too many internal signals directly to PMOD can increase timing and routing burden.  
Therefore, it is better to use a page select method and output only a few important states.

Recommended page examples are:

- page 0: an 8-bit status group containing `phase`, `busy`, `done`, `error`, `result_valid`, and `row_inject_ready`
- page 1: an 8-bit progress group formed from low counter bits
- page 2: an 8-bit status group formed from output status/debug bits

---

## 10. Top-level Signal Contract Summary

This section gathers only the key signals of each interface.  
For the detailed CSV, also check `Internal_Signal_MemoryMap/ACCELERATOR_SIGNALS(Subsystem Signals).csv`.

The signals summarized here are not all the same kind of port.  
Some signals are top-level ports directly connected to the SoC wrapper, some are internal buses between the APB I/F and Decoder, and some are boundary interfaces between different modules such as the Scheduler and SA Core.  
What matters more than the signal name itself is "who creates it, who consumes it, and in which cycle it is meaningful".

The direction of each signal shows the direction in which data or control information flows.  
For example, `cfg_act_prec` is a setting value stored by the RegBank and used by the Frontend/FSM, so its direction is `RegBank -> Frontend/FSM`.  
`result_ready` is a signal by which the Output block tells the SA Core that it is ready to receive, so its direction is `Output -> SA/FSM`.  
If this direction is misunderstood, two modules may drive the same signal at the same time, or no module may drive it at all.

### 10.1 APB Internal Bus Contract

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `local_addr[11:0]` | APB I/F -> Decoder | Address Decoder | 4 KiB local offset. Needed so the internal register map remains unchanged even if the subsystem slot changes. |
| `bus_wdata[31:0]` | APB I/F -> Decoder/RegBank/Frontend | Address Decoder, RegBank, Frontend | APB write payload. Allows register writes and row injection data pushes to share the same 32-bit payload form. |
| `bus_wena` | APB I/F -> Decoder | Address Decoder | Valid write access event. Internal modules that do not know APB phase can start write handling using only this pulse. |
| `bus_rena` | APB I/F -> Decoder | Address Decoder | Valid read access event. Used by the Decoder to select the read source. |
| `bus_rdata[31:0]` | RegBank/Output -> APB I/F | RegBank, Output read path | APB read data. Final 32-bit word returned to firmware. |
| `bus_ready` | internal target -> APB I/F | Decoder/target path | Indicates whether the access can complete. If 0, APB `PREADY` can be lowered to delay the transaction. |
| `bus_err` | internal target -> APB I/F | Decoder/target path | Indicates whether the access is an error. Basis for `PSLVERR` and `ERROR_CODE` policy. |

The purpose of the APB internal bus contract is to convert the external APB protocol into one read/write event that is easy to use internally.  
`bus_wena` and `bus_rena` are the basis for the Decoder to decide whether it must process an actual access in the current cycle.  
`bus_ready` and `bus_err` are signals that return the internal block's processing result back to APB `PREADY` and `PSLVERR`.

### 10.2 Configuration/Status Contract

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `cfg_act_prec[1:0]` | RegBank -> Frontend/FSM | Frontend, Main FSM | Activation precision. Used by the Frontend as the standard for unpacking activation words. |
| `cfg_wgt_prec[1:0]` | RegBank -> Frontend/FSM | Frontend, Main FSM | Weight precision. Used by the Frontend as the standard for unpacking weight words. |
| `tile_m` | RegBank -> FSM/Scheduler | Main FSM, Scheduler | Current tile row count. Defines the expected number of results and row scheduling range. |
| `tile_n` | RegBank -> FSM/Scheduler | Main FSM, Scheduler | Current tile column count. Defines the number of output results and column range. |
| `tile_k` | RegBank -> FSM/Scheduler | Main FSM, Scheduler | Dot product length. Needed to calculate weight/input counts and compute completion conditions. |
| `phase` | FSM -> RegBank/Decoder | RegBank, Address Decoder | Current FSM state. Basis for firmware status and legal access decisions. |
| `busy` | FSM -> RegBank | RegBank | Indicates tile execution is in progress. Basis for blocking config changes while busy. |
| `done` | FSM -> RegBank/IRQ | RegBank, IRQ Logic | Tile completion state. Cause of firmware polling completion and done interrupt. |
| `error` | FSM -> RegBank/IRQ | RegBank, IRQ Logic | Indicates that a control sequence or APB access error occurred. |

The configuration/status contract separates setting values written by firmware from status values generated by hardware.  
`cfg_*` and `tile_*` are input conditions stored by the RegBank and provided to internal blocks.  
`phase`, `busy`, `done`, and `error` are current progress states generated by the FSM and shown to firmware by the RegBank and IRQ Logic.

### 10.3 Row Injection Contract

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `row_inject_we` | Decoder -> Frontend | Precision Row Injection Frontend | Indicates that a legal `ROW_INJECT_DATA` write occurred. Starts conversion of the packed APB word into an internal token. |
| `row_inject_mode` | FSM -> Frontend/Scheduler | Frontend, Scheduler | 0 means weight, 1 means activation. This is generated from FSM phase, not from a firmware mode bit. |
| `row_inject_region_offset[7:0]` | Decoder -> Frontend | Precision Row Injection Frontend | Offset inside the injection window. Can be used for row/word index policy. |
| `row_inject_data[31:0]` | APB/Decoder -> Frontend | Precision Row Injection Frontend | Packed 32-bit APB word. Interpreted as 1, 2, 4, or 8 elements depending on precision. |
| `frontend_valid` | Frontend -> FIFO | Row Injection FIFO/Staging | Indicates that an unpacked token is valid. |
| `frontend_ready` | FIFO -> Frontend/APB | Frontend, APB wait path | Indicates that the FIFO is ready to receive a token. If 0, the push is delayed to prevent data loss. |
| `frontend_mode`, `frontend_row_idx` | Frontend -> FIFO | Row Injection FIFO/Staging | Transfers the token meaning and logical row position together. |
| `lane_valid[INJECT_LANES_MAX-1:0]` | Frontend -> FIFO | Row Injection FIFO/Staging | Valid element lane marks. Prevents padding lanes from entering computation. |
| `lane_data[INJECT_LANES_MAX*32-1:0]` | Frontend -> FIFO | Row Injection FIFO/Staging | Signed-extended element payload. Prevents downstream blocks from repeating precision-specific bit slicing. |
| `row_fifo_valid/row_fifo_ready` | FIFO <-> Scheduler | FIFO/Staging, Scheduler | FIFO token pop handshake. Only in cycles where both are 1 is the Scheduler considered to have consumed a token. |
| `row_fifo_mode`, `row_fifo_row_idx`, `row_fifo_lane_valid`, `row_fifo_lane_data` | FIFO -> Scheduler | SA Injection Scheduler | Token payload and metadata stored by the FIFO. The Scheduler delivers these to the SA Core with the correct timing. |

The core of the row injection contract is to clearly define the moment when one APB write becomes an internal token.  
`row_inject_we` means the Decoder detected a write to the row injection window, and `frontend_valid/frontend_ready` determines whether the unpacked token actually moved to the next stage.  
`lane_valid` and `lane_data` allow downstream blocks to see the precision-specific packing result in a common form.

### 10.4 SA Control Contract

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `sa_weight_map_en` | FSM -> Scheduler/SA | Scheduler, SA Core | Weight mapping phase enable. Tells downstream blocks that incoming tokens should be interpreted toward PE-local weight mapping. |
| `sa_act_stream_en` | FSM -> Scheduler/SA | Scheduler, SA Core | Activation streaming phase enable. Tells downstream blocks that incoming tokens should be interpreted as compute inputs. |
| `sa_compute_en` | FSM -> SA | SA Core | Compute operation enable. The internal SA compute structure is free, but the top-level phase standard is delivered through this signal. |
| `sa_drain_en` | FSM -> SA | SA Core | Result drain operation enable. Indicates the phase where no new input is accepted and remaining results are emitted. |
| `sa_clear` | FSM/Control -> SA | Scheduler, SA Core, FIFO policy | Tile-local state clear. Needed to ensure previous tile pending tokens or internal valid state do not remain. |
| `sa_pipeline_empty` | SA -> FSM | Main Control FSM | Indicates that there are no pending results in the internal pipeline. Basis for the FSM to safely move to `DONE`. |
| `weight_map_done` | Scheduler/SA -> FSM | Main Control FSM | Required weight mapping completion state. If asserted too early, activations may compute with incorrect weights. |
| `activation_input_done` | Scheduler/SA -> FSM | Main Control FSM | Required activation input completion state. Needed before moving to the drain phase. |

The SA control contract is a group of signals by which the FSM tells the compute blocks which operations are allowed in the current phase.  
The Scheduler and SA Core use these enables to decide whether incoming tokens are handled as weight mapping or activation streaming.  
Completion signals flow in the opposite direction and tell the FSM whether the system may move to the next phase.

### 10.5 SA Core Boundary Contract

This subsection does not define SA Core internal PE signals or MAC submodule signals.  
It defines only the module-to-module boundary interface that the Scheduler, FSM, and Output block must match with the SA Core.  
PE, MAC, forwarding, accumulator, local storage, and internal ready/valid names are decided by the SA Core implementer in a separate internal spec.

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `sa_row_valid` | Scheduler -> SA Core | Systolic Array Core | Indicates that the row token provided by the Scheduler is valid. |
| `sa_row_ready` | SA Core -> Scheduler | SA Injection Scheduler | Indicates that the SA Core can receive a row token. If 0, the Scheduler must preserve the token. |
| `sa_row_mode` | Scheduler/FSM -> SA Core | Systolic Array Core | 0 means weight mapping token, 1 means activation stream token. |
| `sa_row_idx` | Scheduler -> SA Core | Systolic Array Core | Logical row index. Even if the SA internal placement method differs, the external coordinate meaning must be preserved. |
| `sa_row_lane_valid[INJECT_LANES_MAX-1:0]` | Scheduler -> SA Core | Systolic Array Core | Valid lane marks inside the current row token. |
| `sa_row_lane_data[INJECT_LANES_MAX*32-1:0]` | Scheduler -> SA Core | Systolic Array Core | Signed-extended lane payload. Whether it means activation or weight is decided by mode. |
| `sa_weight_map_en` | FSM -> SA Core/Scheduler | SA Core, Scheduler | Weight mapping phase enable. |
| `sa_act_stream_en` | FSM -> SA Core/Scheduler | SA Core, Scheduler | Activation streaming phase enable. |
| `sa_compute_en` | FSM -> SA Core | Systolic Array Core | Compute operation enable. |
| `sa_drain_en` | FSM -> SA Core | Systolic Array Core | Result drain operation enable. |
| `sa_clear` | FSM/Control -> SA Core | Systolic Array Core | Tile-local SA state clear. |
| `weight_map_done` | SA Core/Scheduler -> FSM | Main Control FSM | Required weight mapping completion state. |
| `activation_input_done` | SA Core/Scheduler -> FSM | Main Control FSM | Required activation input completion state. |
| `sa_pipeline_empty` | SA Core -> FSM | Main Control FSM | Indicates that there are no pending results left. |

The key point of this table is to allow other modules to use the SA Core without fixing its internal structure.  
The Scheduler provides a row token stream to the SA Core, and the FSM provides phase enable and clear.  
The SA Core provides completion status and result stream externally.  
If this boundary is maintained, top-level integration can remain stable regardless of how PEs and MACs are separated inside the SA Core.

### 10.6 Output Contract

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `result_valid` | SA -> Output | Output Result Interface | Indicates that the SA Core is providing a result payload. |
| `result_ready` | Output -> SA/FSM | SA Core, Main FSM | Indicates that the Output block is ready to receive a result. Result count must increase only when `result_valid && result_ready`. |
| `result_row` | SA -> Output | Output Result Interface | Output tile row index of the result. |
| `result_col` | SA -> Output | Output Result Interface | Output tile column index of the result. |
| `result_data[RESULT_W-1:0]` | SA -> Output | Output Result Interface | Result payload. Actual width and format are decided by the SA/Output owners and exposed as metadata. |
| `result_last` | SA -> Output | Output Result Interface, Main FSM | Last-result marker for the tile. Used to determine drain completion. |
| `out_window_re` | APB/Decoder -> Output | Output Result Interface | Indicates that firmware read an address inside `OUTPUT_READ_WINDOW`. |
| `out_window_word_idx[5:0]` | APB/Decoder -> Output | Output Result Interface | 32-bit output word index based at `0x400`. Used by the Output block to select the returned word. |
| `out_window_ready` | Output -> APB/Decoder | APB read path | Indicates that the output window read can be accepted. If 0, APB wait may be needed. |
| `out_window_rdata[31:0]` | Output -> APB/Decoder | APB read path | Selected output word returned to firmware. |
| `out_window_err` | Output -> APB/Decoder/FSM | Error path | Output window read error such as no result or word index out of range. |
| `out_result_valid` | Output -> RegBank/FSM | RegBank, Main FSM | Indicates that there is a result set for firmware to read. |
| `out_busy` | Output -> RegBank | RegBank | Indicates that the Output block is internally processing. |
| `out_count` | Output -> RegBank/FSM | RegBank, Main FSM | Number of results accepted by the Output block. |
| `out_window_words` | Output -> RegBank | RegBank | Number of valid 32-bit words occupied by the current tile result in the output window. |
| `out_format_id` | Output -> RegBank | RegBank | Output format identifier. Used by firmware to check result interpretation. |
| `out_words_per_element` | Output -> RegBank | RegBank | Number of 32-bit words needed to read one output element. |

The output contract is the boundary where computation results become firmware-readable data.  
The SA Core provides result payload and position information, while the Output block reports whether it can receive them and provides 32-bit words for direct output window reads.  
Thanks to this contract, even if the Output internal storage method changes, firmware can continue to sequentially read the `0x400-0x4FF` window.

### 10.7 IRQ/PMOD/SoC Control Contract

| Signal Name | Direction | Peer Module | Meaning or Purpose |
|---|---|---|---|
| `ss_ctrl_i[7:0]` | SoC controller -> subsystem | APB/control path | Control bus delivered from the SoC controller to the subsystem. Bit 0 means standard clock enable and bit 1 means fast clock enable. This is a different control layer from accelerator-internal `CONTROL.start`. |
| `irq_en_i` | SoC -> IRQ Logic | IRQ Logic | SoC-level interrupt enable. Gates `irq_o` together with local enable. |
| `irq_o` | IRQ Logic -> SoC | SoC wrapper | One-cycle interrupt pulse sent to the CPU. |
| `irq_status` | IRQ Logic -> RegBank | RegBank | Sticky pending bits. Allows firmware to identify the cause even if the pulse is missed. |
| `irq_enable` | RegBank -> IRQ Logic | IRQ Logic | Local interrupt enable. Used for enable policy per done/error event. |
| `pmod_0_gpi[3:0]`, `pmod_1_gpi[3:0]` | PMOD pins -> RegBank/PMOD Debug | RegBank, PMOD Debug | Official SoC PMOD input values. Used for firmware readback and debug logic. |
| `pmod_0_gpo[3:0]`, `pmod_1_gpo[3:0]` | PMOD Debug -> PMOD pins | SoC PMOD pins | Outputs the selected 8-bit debug page split into two 4-bit output ports. |
| `pmod_0_gpio_oe[3:0]`, `pmod_1_gpio_oe[3:0]` | PMOD Debug -> PMOD pins | SoC PMOD pins | PMOD output enable. In the SoC convention, 0 means drive and 1 means input/tristate. |

The IRQ/PMOD/SoC control contract contains signals needed for SoC integration and debug, separate from the compute data path.  
IRQ is the path for notifying the CPU of done/error events, and PMOD is the debug path for observing internal state on external pins.  
Neither is a path for sending matrix operands, so their roles must not be mixed with the row injection/output protocol.

PMOD is an area where the final wrapper form may differ.  
If the SoC Documentation and student subsystem examples provide two 4-bit ports, use the `pmod_0_*` and `pmod_1_*` signals in the table directly.  
If the current generated SoC in the Didactic-SoC repo provides a 16-bit PMOD GPIO bus, place this logical PMOD debug payload in the lower 8 bits and keep the upper 8 bits as input/tristate through a top integration adapter.  
With this organization, the PMOD Debug block itself only needs to create an 8-bit debug page, and wrapper representation differences can be handled at the system connection boundary.

---

## 11. Normal and Error Sequences

### 11.1 Normal Tile Execution Sequence

The normal sequence proceeds as follows.

This sequence shows both the write/read order performed by firmware and the internal hardware phase transitions.  
Firmware only uses registers and data windows, but behind them, the APB I/F, Decoder, RegBank, FSM, Frontend, Scheduler, SA Core, PE internal compute path, and Output block each perform their role in order.  
Therefore, when verifying the normal sequence, we must check not only whether firmware commands are correct, but also whether internal valid/ready accepts and FSM phase transitions occur correctly at each step.

0. Firmware/HAL first configures the target subsystem clock enable, reset release, IRQ forwarding, and PMOD routing in the SoC controller block.
1. After reset release, the accelerator FSM is in `IDLE_CFG`.
2. Firmware sets precision in `CONFIG`.
3. Firmware sets tile size in `DIM`.
4. If needed, firmware sets accelerator-local `IRQ_ENABLE` and `SA_PMOD_CTRL`.
5. Firmware writes `CONTROL.start=1`.
6. The FSM moves to `WEIGHT_MAP`.
7. Firmware writes weight words sequentially to `ROW_INJECT_DATA`.
8. The Frontend unpacks them using `wgt_prec`.
9. The Scheduler/SA performs weight mapping.
10. When weight mapping completes, the FSM moves to `ACT_STREAM_COMPUTE`.
11. Firmware writes activation words sequentially to `ROW_INJECT_DATA`.
12. The Frontend unpacks them using `act_prec`.
13. The Scheduler delivers the activation stream to the PE path.
14. The PE uses activation operands and PE-local weights to perform internal multiply-accumulate behavior.
15. The PE internal compute logic updates partial accumulation or result payload.
16. The SA Core organizes PE internal computation results into the SA result interface.
17. When input completes, the FSM moves to `DRAIN_WRITEBACK`.
18. SA results are transferred to the Output block through the `result_valid/result_ready` handshake.
19. When all expected results are accepted, the FSM moves to `DONE`.
20. If IRQ is enabled, a done event occurs.
21. Firmware reads results using the output read registers/window.
22. Firmware prepares the next tile using `clear_done` or the next start sequence.

The most important checkpoints in this sequence are `CONTROL.start`, `WEIGHT_MAP`, `ACT_STREAM_COMPUTE`, `DRAIN_WRITEBACK`, and `DONE`.  
Before `start`, settings are fixed. In `WEIGHT_MAP`, only weights are injected. In `ACT_STREAM_COMPUTE`, only activations are injected. In `DRAIN_WRITEBACK`, no new input is injected and results are transferred.  
Keeping this separation allows firmware and RTL to share the same execution model.

Also, data movement is not considered complete simply because a write occurred.  
An internal token or result is considered accepted in a cycle where `valid && ready` is true.  
Therefore, count registers and FSM transitions should also increase or move based on this accept event.

### 11.2 Order Firmware Must Follow

Firmware must follow these rules.

- Set `CONFIG` and `DIM` before start.
- Push weights only in `WEIGHT_MAP`.
- Push activations only in `ACT_STREAM_COMPUTE`.
- Access `ROW_INJECT_DATA` only with 32-bit aligned writes.
- Do not read `OUTPUT_READ_WINDOW` if there is no output result.
- Read `OUTPUT_READ_WINDOW` only within the valid word range indicated by `OUTPUT_WORDS`.
- If `ERROR` occurs, read `ERROR_CODE` and clear or reset.

These rules are needed because firmware cannot directly see hardware internal state.  
If firmware changes `CONFIG` after start, hardware may already contain data interpreted using the previous precision.  
If firmware reads `OUTPUT_READ_WINDOW` when there is no output result, it cannot know whether the returned value is a real result.  
Therefore, the HAL should wrap this order at the function level so application code cannot easily create an invalid sequence.

When designing the actual firmware API, it is safer to provide functions for configuration, start, weight push, activation push, status check, output read, and clear instead of exposing low-level register access directly.  
Then application code can focus on full matrix tiling, while state-specific legal access is managed inside the HAL.

### 11.3 Error Sequence Examples

The following actions are treated as errors.

| Situation | Why It Is a Problem |
|---|---|
| `CONFIG` write while `busy=1` | The precision interpretation of data that already entered and new data may differ |
| `DIM` write while `busy=1` | Expected count and result count may change |
| `ROW_INJECT_DATA` write in `IDLE_CFG` | Weight mapping phase has not started yet |
| Activation data push before `WEIGHT_MAP` | SA internal weights may not be ready |
| Row injection write during `DRAIN_WRITEBACK` | This phase no longer accepts new input |
| Access to an unassigned address | Access outside the Decoder contract |
| Unaligned access | Violation of the 32-bit word contract |
| `OUTPUT_READ_WINDOW` read when there is no result | There is no firmware-readable output |
| Output window valid range exceeded | Request for a word not provided by the Output block |

Error sequences are clearly defined so invalid usage does not pass silently.  
If hardware ignores illegal accesses, firmware may believe the operation succeeded and only see an incorrect result later.  
In contrast, if the error is exposed clearly, firmware/HAL or testbenches can quickly find the invalid sequence.

In particular, `CONFIG`/`DIM` writes while busy, `ROW_INJECT_DATA` writes in the wrong phase, and output reads without a result are mistakes that may occur often during early development.  
These cases should be intentionally generated in testbenches to check that `STATUS.error`, `ERROR_CODE`, and the `PSLVERR` policy behave as expected.

### 11.4 What `ERROR` Does Not Mean

`ERROR` means a top-level control error.  
SA internal numeric policy or Output internal representation is not included in this document's `ERROR` conditions.

For example, the SA/Output owners decide what bit width to use for storing internal computation results for a specific precision combination, or how to handle values outside an internal numeric range.  
That policy should be explained through output format metadata and separate module documentation.

This separation is important to divide responsibilities between team members.  
The APB/Decoder/RegBank/FSM owner is responsible for catching incorrect control sequences and invalid register accesses.  
The PE/Output owners are responsible for defining internal arithmetic representation and result format.  
If both responsibilities are placed into the same `ERROR` path, firmware cannot know whether an observed error came from a control sequence problem or an internal computation policy.

---

## 12. Implementation Criteria by Team Member

### 12.1 APB/Decoder/RegBank/FSM Owner Criteria

This owner implements the most concrete top-level control contract.

The following items must be fixed and implemented.

- APB setup/access phase handling
- `PREADY`, `PSLVERR` generation
- `PADDR[11:0]` local decode
- Register map implementation
- State-specific legal/illegal access decisions
- `CONFIG`, `DIM` write protection
- `ROW_INJECT_DATA` push generation
- 6-state FSM transition
- Status/counter exposure
- IRQ sticky status and pulse generation
- PMOD debug control

This owner does not force the internal implementation of other blocks.  
Instead, this owner provides clear input/output signals and handshake meanings that other blocks must match.

### 12.2 Row Injection Frontend Owner Criteria

This owner converts APB 32-bit words into precision-specific lane data.

The following items must be matched.

- `INT4`, `INT8`, `INT16`, `INT32` decoding
- LSB-first element order
- signed two's complement sign extension
- `lane_valid` generation
- `frontend_valid/frontend_ready` handshake
- Select `act_prec` or `wgt_prec` according to `row_inject_mode`

The number of internal pipeline stages can be chosen freely.  
However, if the handshake breaks, APB write data loss occurs, so `ready` handling is very important.

### 12.3 FIFO/Staging Owner Criteria

This owner handles buffering between the Frontend and Scheduler.

The following items must be matched.

- Preserve input token order
- Provide backpressure through `frontend_ready`
- `row_fifo_valid/row_fifo_ready` handshake
- Handle internal pending tokens on reset/clear

The FIFO depth and internal structure are decided by the owner.

### 12.4 Scheduler Owner Criteria

This owner aligns row tokens to SA Core timing.

The following items must be matched.

- Interpret `row_inject_mode`
- Weight mapping timing
- Activation streaming timing
- Transfer row index and lane valid
- `weight_map_done`
- `activation_input_done`
- Backpressure handling according to SA Core ready

The internal skew, delay, and row ordering method are decided by the owner.  
However, completion conditions must be provided as clear signals so the FSM can move to the next state.

### 12.5 SA Core Owner Criteria

This owner performs the actual computation.

The following items must be matched.

- Receive weight tokens
- Receive activation tokens
- Use precision-specific operand interpretation results
- Handle `sa_clear` and phase enable signals
- Create result payloads
- `result_valid/result_ready` handshake
- Provide `result_row`, `result_col`, and `result_last`
- Provide `sa_pipeline_empty`

The PE internal structure and multiply-accumulate implementation method are decided by the owner.  
Rather than forcing PE internals directly, the SA Core owner organizes the boundary so tokens entering from the Scheduler are delivered to the PE internal compute path and the results are gathered into the final `result_valid/result_ready/result_row/result_col/result_data/result_last` interface.

### 12.6 PE Owner Criteria (Including MAC Behavior)

This owner manages weight stationary state, activation forwarding, multiply-accumulate updates, and PE-local result state inside the SA Core.

This document does not force PE internal signal names or MAC submodule port names.  
Whether the MAC is implemented directly inside the PE in RTL, placed as a separate child module, or where the accumulator is located is decided by the PE/SA Core owners.

The following items should be considered during implementation.

- Where weight stationary state is stored and when it is considered valid
- In which direction and timing activations are transferred
- How operand valid, local state valid, and result valid are managed internally
- Under which conditions multiply-accumulate updates are performed
- Whether partial results or accumulators are placed inside the PE or in a separate datapath
- How old tile state is removed on clear/reset or new tile start
- How pipeline depth and forwarding delay affect SA Core result timing
- How results from a PE or PE group are gathered into the final SA Core result stream
- How signed two's complement operand interpretation and precision combination handling are guaranteed

The PE internal forwarding direction, pipeline depth, accumulator location, multiplier structure, and PE-local storage structure are decided by the owner.  
However, outside the SA Core, the Scheduler row token stream and Output result stream contract must remain stable.

### 12.7 Output Owner Criteria

This owner handles result accept and the direct output read window protocol.

The following items must be matched.

- Accept SA results through the `result_valid/result_ready` handshake
- Interpret `result_row`, `result_col`, `result_data`, and `result_last`
- Handle `OUTPUT_READ_WINDOW` read requests
- `out_window_ready`
- `out_window_rdata[31:0]`
- `out_window_err`
- `out_window_words`
- `out_result_valid`
- `out_format_id`
- `out_words_per_element`

The internal storage structure, result format, and result width are decided by the owner.  
However, firmware must be able to directly read 32-bit words from the `0x400-0x4FF` window.

---

## 13. Items That Must Be Agreed in Meetings

This document defines the top-level contract, but some detailed values still require additional agreement between team members.  
The following items must be aligned with each owner before RTL implementation.

### 13.1 Row Injection Count Basis

The basis of the following counters is fixed in the top-level contract.

- `WEIGHT_COUNT`
- `INPUT_COUNT`
- `DRAIN_COUNT`
- `OUT_COUNT`

The basis is:

- `WEIGHT_COUNT` and `INPUT_COUNT`: accepted 32-bit `ROW_INJECT_DATA` write words
- Output count: result elements accepted by `result_valid && result_ready`

Because the number of elements inside one word changes depending on precision, using unpacked elements as the basis for `WEIGHT_COUNT` and `INPUT_COUNT` would complicate firmware loops and count interpretation.  
If the element count is needed, it can be checked through Frontend `lane_count` or separate debug status, while the firmware-visible load count remains based on APB write words.

### 13.2 Row Index Generation Method

The team must decide how to generate the logical row index for row tokens. In the document boundary, it is transferred as `frontend_row_idx` or `row_fifo_row_idx` on the Frontend/FIFO side and `sa_row_idx` on the Scheduler/SA Core side.

Possible methods include:

- Use part of the address offset
- Use an internal row counter
- Let the Scheduler decide based on count

Whichever method is used, firmware and testbenches must be able to generate the same order.

### 13.3 Expected Weight/Input/Result Count

For the FSM to transition states, it must know:

- Whether weight mapping is complete
- Whether activation input is complete
- Whether all results have been accepted by the Output block

These conditions depend on `tile_m`, `tile_n`, `tile_k`, array parameters, and scheduler policy.  
Therefore, the FSM owner and Scheduler/SA owners must align on the count formula and done signals.

### 13.4 Output Format Metadata

The Output owner must provide:

- `out_format_id`
- `out_words_per_element`
- `out_window_words`
- `out_result_valid`

Firmware uses this information to construct the output read loop.

### 13.5 PMOD Debug Page

The team must decide which signals to show on PMOD.

Based on the official SoC interface, the logical PMOD debug output available to our subsystem is 8 bits formed by `pmod_0_gpo[3:0]` and `pmod_1_gpo[3:0]`.  
Even if the final generated wrapper provides a 16-bit PMOD GPIO bus, the debug payload defined in this document remains centered on the lower 8 bits.  
Because too many signals cannot be sent out at once, a page select method is needed.  
At minimum, the following information is useful for debug.

- FSM phase
- `busy`, `done`, `error`
- row injection ready
- output result valid
- counter low bits

---

## 14. Verification Criteria

### 14.1 APB/Register Verification

The following items should be tested.

- reset value
- `CONTROL.start`
- `CONFIG` write/read
- `DIM` write/read
- RO register write policy
- W1C clear policy
- unaligned access error
- reserved address error
- `PREADY` wait state
- `PSLVERR` generation

### 14.2 FSM Verification

The following sequences should be tested.

- normal `IDLE_CFG -> WEIGHT_MAP -> ACT_STREAM_COMPUTE -> DRAIN_WRITEBACK -> DONE`
- accesses allowed in each state
- accesses forbidden in each state
- entry into `ERROR`
- `clear_error`
- `soft_reset`
- `done` sticky status

### 14.3 Precision/Packing Verification

The following items should be tested.

- `INT4` unpack
- `INT8` unpack
- `INT16` unpack
- `INT32` unpack
- activation/weight precision 16-combination setting
- signed two's complement sign extension
- LSB-first element order
- `lane_valid` of the last word

### 14.4 Row Injection Verification

The following items should be tested.

- whether `ROW_INJECT_DATA` write becomes a weight token in `WEIGHT_MAP`
- whether a write to the same address becomes an activation token in `ACT_STREAM_COMPUTE`
- whether `row_inject_mode` comes from FSM phase, not from a firmware register
- whether FIFO full backpressure leads to an APB wait state
- whether data order is preserved

### 14.5 PE Internal Compute Path Verification

The following items should be tested.

- whether the SA Core becomes ready to perform activation compute after the weight mapping phase
- whether the SA Core result stream is generated within the expected timing after activation stream input
- whether `INT4`, `INT8`, `INT16`, and `INT32` operands are computed using signed two's complement interpretation
- whether PE internal pipeline latency is consistent with SA Core `result_valid` timing
- whether internal valid state from a previous tile does not remain after clear/reset or new tile start
- whether the SA Core internal implementation separates APB/control errors from numeric processing policy instead of directly creating top-level `ERROR`
- whether the final `result_valid/result_ready/result_row/result_col/result_data/result_last` boundary contract is maintained

### 14.6 Output Verification

The following items should be tested.

- `result_valid/result_ready` accept
- whether result count does not increase when the Output block has `result_ready=0`
- output read error handling when `out_result_valid=0`
- error handling when the `OUTPUT_READ_WINDOW` valid word range is exceeded
- APB wait state handling when `out_window_ready=0`
- whether `out_window_rdata[31:0]` is the correct 32-bit word during normal reads
- whether `OUTPUT_WORDS` can be used as the firmware loop termination condition

### 14.7 IRQ/PMOD Verification

The following items should be tested.

- whether a done event sets `IRQ_STATUS`
- whether an error event sets `IRQ_STATUS`
- whether W1C clear works
- whether `irq_o` does not occur when local `IRQ_ENABLE` is off
- whether `irq_o` does not occur when `irq_en_i` is off
- whether PMOD is not driven when `debug_en=0`
- whether the selected page is output when PMOD `debug_en=1`
- whether `pmod_0_gpio_oe[3:0]` and `pmod_1_gpio_oe[3:0]` polarity match the SoC wrapper

---

## 15. Quick Checklist

When team members are unsure during implementation, check the following questions first.

- Is my module looking at an absolute address?
- Does it operate only based on the `PADDR[11:0]` local offset?
- Is APB access based on 32-bit aligned full-word access?
- Is `ROW_INJECT_DATA` kept as the shared weight/activation window?
- Are weight and activation distinguished by FSM phase, not by a firmware mode bit?
- Are `CONFIG` and `DIM` blocked from changing while busy?
- Does the data transfer count increase only when `valid && ready`?
- Is the normal path avoiding unnecessary APB waits?
- Is `ready=0` used only as exceptional handling to prevent data loss?
- Is every APB write that receives `PREADY=1` actually accepted internally?
- Does the PE internal compute path operate based on signed-extended 32-bit operands?
- Is PE internal numeric policy kept separate from top-level `ERROR`?
- Is the top-level document avoiding excessive constraints on PE internal implementation?
- Is the top level avoiding assumptions about Output internal implementation?
- Does firmware output read use the `0x400-0x4FF` direct memory-mapped window in 32-bit word units?
- Are IRQ status and IRQ pulse distinguished?
- Is the PMOD logical debug payload organized as 8 bits, with an adapter according to whether the final wrapper uses 2x4 ports or a 16-bit bus?
- Is PMOD output enable polarity matched with the SoC wrapper?

The core idea of this document is not to force every internal implementation into one shape.  
Each owner can freely design their own module, but the top-level visible signal meanings and state meanings must remain the same.

