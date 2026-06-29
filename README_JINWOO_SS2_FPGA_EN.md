# Jinwoo SS2 FPGA Bring-up Guide

This document summarizes the current `jinwoo` branch structure, required setup, and the workflow for synthesizing and running the CPU+SS2 subsystem on the PYNQ-Z2 FPGA.

The current goal is to validate the RISC-V host CPU and the `SS2` systolic-array subsystem on FPGA with real bare-metal C tests before moving toward ASIC integration.

## Current Status

- FPGA board: PYNQ-Z2
- JTAG/ELF loader: FT232H single-channel module
- UART output bridge: STM32 Nucleo-F411RE
- SoC CPU: Ibex/RISC-V bare-metal flow
- Integrated subsystem: `Student_SS_2` directly instantiates `src/ss_integration/subsystem_topmodule.sv`
- SS2 MMIO base address: `0x0105_2000`
- Validated flow:
  - FPGA bitstream generation
  - PYNQ-Z2 bitstream programming
  - RISC-V ELF load/resume through FT232H JTAG
  - UART result capture through the Nucleo bridge
  - `ss2_smoke` and `ss2_gemm` hardware runs passed
- Notes:
  - Timing closure is not complete yet.
  - The full 32x32x32 header sweep has a tile-based hardware execution path, but a stable end-to-end full-header sweep still needs further verification.

## Required Environment

The following tools must be available on each developer machine.

| Item | Purpose |
|---|---|
| Vivado | PYNQ-Z2 synthesis, implementation, bitstream generation, and programming |
| Bender | RTL dependency and filelist generation |
| RISC-V GCC toolchain | Bare-metal ELF build for the RISC-V CPU on FPGA |
| OpenOCD | FT232H JTAG ELF load/run and Nucleo flash/reset |
| ARM GCC toolchain | Nucleo UART bridge firmware build |
| Python 3 | UART capture and header sweep automation |

Vivado and the Edu4Chip environment may be installed in different locations on different machines. Each user must set the following variables for their own setup.

| Variable | Meaning |
|---|---|
| `EDU_ENV` | Path to the Edu4Chip environment setup script |
| `VIVADO_SETTINGS` | Path to Vivado `settings64.sh` |

Example only. Replace these paths with the actual paths on your machine.

```bash
export EDU_ENV=/path/to/Edu4Chip/env.sh
export VIVADO_SETTINGS=/path/to/Xilinx/<version>/Vivado/settings64.sh
```

The automation scripts source the files pointed to by these variables. To source the environment manually:

```bash
source "$EDU_ENV"
source "$VIVADO_SETTINGS"
```

## Hardware Setup

This branch uses a local PYNQ-Z2 flow instead of the course default PYNQ-Z1 + FT4232H setup.

| Device | Role |
|---|---|
| PYNQ-Z2 | FPGA board that runs the CPU+SS2 bitstream |
| FT232H | RISC-V JTAG connection and ELF download |
| Nucleo-F411RE | UART bridge from FPGA UART TX/RX to the host PC, usually `/dev/ttyACM0` |

Use `Ubuntu_Only/PYNQ_Z2_FT232H_NUCLEO_HW_SETUP.md` as the current wiring reference.

## Key File Structure

### SS2 RTL

| File or directory | Role |
|---|---|
| `src/ss_integration/` | Main SS2 subsystem RTL implementation |
| `src/ss_integration/subsystem_topmodule.sv` | SS2 top module |
| `src/ss_integration/subsystem_addr_decoder.sv` | APB local address decoder |
| `src/ss_integration/subsystem_regbank.sv` | Control, status, and configuration registers |
| `src/ss_integration/subsystem_sa.sv` | Systolic-array datapath |
| `src/ss_integration/subsystem_output_buffer.sv` | Result buffer read by the CPU |
| `src/rtl/Student_SS_2.sv` | Connects SS2 to Didactic SoC student slot 2 |
| `src/generated/ss2_wrapper_0.v` | Wrapper between the generated SoC top and `Student_SS_2` |
| `src/generated/Didactic.v` | Generated Didactic SoC top |

### FPGA Z2 Flow

| File | Role |
|---|---|
| `fpga/Makefile.z2_course_io_ft232h_nucleo` | Separate Makefile for PYNQ-Z2 + FT232H + Nucleo |
| `fpga/rtl/DidacticZ2_FT232H_Nucleo.v` | PYNQ-Z2 FPGA top wrapper |
| `fpga/constraints/z2_course_io_ft232h_nucleo.xdc` | PYNQ-Z2 pin and timing constraints |
| `fpga/scripts/run_xilinx_z2_course_io_ft232h_nucleo.tcl` | Vivado synthesis, implementation, and bitstream Tcl |
| `fpga/scripts/program_z2_course_io_ft232h_nucleo.tcl` | FPGA programming through Vivado hardware manager |
| `fpga/utils/openocd-didactic-ft232h-z2.cfg` | FT232H JTAG OpenOCD configuration |

### Bare-metal Software

| File or directory | Role |
|---|---|
| `fpga/sw/Makefile` | RISC-V ELF build flow |
| `fpga/sw/common/ss2_sa.h` | SS2 MMIO HAL |
| `fpga/sw/common/ss2_uart_print.h` | UART print helper |
| `fpga/sw/ss2_smoke/` | SS2 register and basic datapath smoke test |
| `fpga/sw/ss2_gemm/` | Simple GEMM hardware test using SS2 |
| `fpga/sw/ss2_pstrb/` | PSTRB behavior test |
| `fpga/sw/gemm_cpu/` | CPU-only GEMM baseline without SS2 |

### Automation Scripts

| File | Role |
|---|---|
| `fpga/scripts/run_z2_gemm_cpu_bringup.sh` | CPU-only baseline bring-up |
| `fpga/scripts/run_z2_ss2_hw_workflow.sh` | Nucleo flash, FPGA program, ELF load, and UART capture |
| `fpga/scripts/run_ss2_header_sweep.py` | Runs GEMM headers one generated tile ELF at a time |
| `fpga/scripts/uart_capture_until.py` | Watches UART output for PASS/FAIL patterns |
| `fpga/nucleo_uart_bridge/` | Nucleo UART bridge firmware |

## Address Map

SS2 is connected to student subsystem slot 2.

| Region | Address |
|---|---|
| Student subsystem base | `0x0105_0000` |
| SS2 slot base | `0x0105_2000` |
| SS2 local register window | `0x0105_2000 + 0x000` |
| SS2 weight stream window | `0x0105_2000 + 0x100` |
| SS2 activation stream window | `0x0105_2000 + 0x200` |
| SS2 output read window | `0x0105_2000 + 0x400` |

Software uses this map in `fpga/sw/common/ss2_sa.h`. RTL implements the same map through `src/rtl/obi_icn_ss.sv` and `src/ss_integration/subsystem_addr_decoder.sv`.

## Bitstream Build

After setting up the environment, run the Z2 FPGA flow from the `fpga` directory.

```bash
cd fpga
make -f Makefile.z2_course_io_ft232h_nucleo all_xilinx
```

The default bitstream path is:

```text
build/fpga/z2_course_io_ft232h_nucleo/didactic-z2_course_io_ft232h_nucleo.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit
```

To inspect the project in Vivado GUI:

```bash
cd fpga
make -f Makefile.z2_course_io_ft232h_nucleo all_xilinx_gui
```

## Full Hardware Workflow

From a fresh system state, use the following command to flash the Nucleo bridge, program the FPGA, build/load RISC-V ELFs, and capture UART output.

```bash
cd fpga
./scripts/run_z2_ss2_hw_workflow.sh --testcases "ss2_smoke ss2_gemm"
```

To rebuild the bitstream before programming:

```bash
cd fpga
./scripts/run_z2_ss2_hw_workflow.sh --rebuild-bitstream --testcases "ss2_smoke ss2_gemm"
```

To include the header sweep:

```bash
cd fpga
./scripts/run_z2_ss2_hw_workflow.sh --testcases "ss2_smoke ss2_gemm ss2_header_sweep"
```

To run a quick partial header sweep:

```bash
cd fpga
HEADER_SWEEP_ARGS="--limit-headers 1" ./scripts/run_z2_ss2_hw_workflow.sh --testcases "ss2_header_sweep"
```

If the UART device differs from the default, pass `UART_DEV` or `--uart-dev`.

```bash
cd fpga
UART_DEV=/dev/ttyACM0 ./scripts/run_z2_ss2_hw_workflow.sh --testcases "ss2_smoke ss2_gemm"
```

## Individual ELF Build and Run

To build RISC-V ELFs individually:

```bash
cd fpga/sw
make TESTCASE=ss2_smoke test
make TESTCASE=ss2_gemm test
```

To load and run one already built ELF:

```bash
cd fpga
./scripts/run_z2_ss2_hw_workflow.sh \
  --skip-nucleo \
  --skip-fpga \
  --elf ../build/fpga/sw/ss2_gemm.elf \
  --name ss2_gemm
```

## Log Location

The automation script creates one timestamped log directory per run.

```text
build/fpga/ss2_hw_workflow/YYYY-MM-DD_HHMMSS/
```

Important logs:

| Log | Meaning |
|---|---|
| `ss2_smoke.openocd.log` | FT232H JTAG ELF load/run log |
| `ss2_smoke.uart.log` | Smoke test output captured through the Nucleo UART bridge |
| `ss2_gemm.openocd.log` | GEMM ELF JTAG load/run log |
| `ss2_gemm.uart.log` | GEMM hardware result output |
| `ss2_header_sweep/` | Generated tile ELFs plus per-tile OpenOCD and UART logs |

To confirm real hardware execution, check the OpenOCD logs for RISC-V TAP detection, hart examination, and `0x01000000` load records. Then check the UART logs for `SS2 ... TEST PASS` or `HEADER_TILE_DONE` output.

## Recommended Verification Order

1. Run `gemm_cpu` or the CPU-only bring-up first to validate board, JTAG, and UART baseline.
2. Run `ss2_smoke` to validate SS2 registers, status, and basic datapath behavior.
3. Run `ss2_gemm` to validate the actual SS2 GEMM path.
4. Run `ss2_pstrb` to validate byte-lane write behavior.
5. Run `ss2_header_sweep` to test 32x32x32 headers one tile at a time.
6. Handle timing closure and full regression stability as separate follow-up work.

## Pre-push Checklist

- Do not commit `build/`, Vivado project output, or temporary logs.
- The Z2 local adaptation files are intentionally separate from the original flow.
  - `fpga/Makefile.z2_course_io_ft232h_nucleo`
  - `fpga/rtl/DidacticZ2_FT232H_Nucleo.v`
  - `fpga/constraints/z2_course_io_ft232h_nucleo.xdc`
  - `fpga/scripts/run_xilinx_z2_course_io_ft232h_nucleo.tcl`
  - `fpga/scripts/program_z2_course_io_ft232h_nucleo.tcl`
  - `fpga/scripts/run_z2_ss2_hw_workflow.sh`
- Review the SS2 integration around these files.
  - `Bender.yml`
  - `src/generated/Didactic.v`
  - `src/generated/ss2_wrapper_0.v`
  - `src/rtl/Student_SS_2.sv`
  - `src/ss_integration/`
  - `fpga/sw/common/ss2_sa.h`
  - `fpga/sw/ss2_smoke/`
  - `fpga/sw/ss2_gemm/`
