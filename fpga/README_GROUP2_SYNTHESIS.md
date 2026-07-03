# Group2 PYNQ-Z2 FPGA Synthesis

This flow builds a PYNQ-Z2 bitstream that includes both the Didactic SoC CPU
and the Group2 subsystem RTL.

## Prerequisites

Each user must set up their own tool paths before running the flow.

- Vivado must be available through `PATH`, or passed with `VIVADO` /
  `VIVADO_SETTINGS`.
- `bender` must be available through `PATH`.
- Repository dependencies must already be fetched according to the course setup.

Example environment setup:

```bash
export VIVADO_SETTINGS=/path/to/Xilinx/2025.2/Vivado/settings64.sh
export BUILD_DIR=$PWD/build
```

## Build Command

From the repository root:

```bash
./fpga/scripts/build_group2_z2_bitstream.sh
```

If Vivado is not already in `PATH`:

```bash
./fpga/scripts/build_group2_z2_bitstream.sh \
  --vivado-settings /path/to/Xilinx/2025.2/Vivado/settings64.sh
```

To inspect the design in Vivado GUI:

```bash
./fpga/scripts/build_group2_z2_bitstream.sh --gui
```

## What This Builds

The script runs the existing Vivado flow with:

- Make target: `z2_course_io_ft232h_nucleo_group2`
- Vivado project name: `didactic-z2_course_io_ft232h_nucleo_group2`
- Top module: `DidacticZ2_FT232H_Nucleo`
- Board part: `xc7z020clg400-1`
- Group2-specific Bender tag: `subsystem_group2_fpga`

The `subsystem_group2_fpga` tag replaces the generated seven-slot subsystem
tie-off/wrapper list with the FPGA-only Group2 wrapper under
`src/subsystem_group2/fpga/`. This keeps the ASIC/default file list unchanged
while allowing the FPGA build to synthesize the CPU and our subsystem together.

## Output Files

Default output directory:

```text
build/fpga/z2_course_io_ft232h_nucleo_group2/
```

Main generated files:

```text
build/fpga/z2_course_io_ft232h_nucleo_group2/didactic-z2_course_io_ft232h_nucleo_group2.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit
build/fpga/z2_course_io_ft232h_nucleo_group2/didactic-z2_course_io_ft232h_nucleo_group2.runs/impl_1/DidacticZ2_FT232H_Nucleo.bin
build/fpga/logs/z2_course_io_ft232h_nucleo_group2.timing.rpt
build/fpga/logs/z2_course_io_ft232h_nucleo_group2.utilization.rpt
```

## Quick Checks

If the script fails before Vivado starts, first check:

```bash
command -v vivado
command -v bender
```

If Vivado runs but the design fails, inspect:

```text
build/fpga/logs/z2_course_io_ft232h_nucleo_group2.check_timing.rpt
build/fpga/logs/z2_course_io_ft232h_nucleo_group2.timing_WORST_50.rpt
build/fpga/logs/z2_course_io_ft232h_nucleo_group2.utilization.rpt
```
