#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPGA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$FPGA_DIR/.." && pwd)"

EDU_ENV="${EDU_ENV:-/home/sinus-phi/Edu4Chip/env.sh}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/home/sinus-phi/Xilinx/2025.2/Vivado/settings64.sh}"
VIVADO="${VIVADO:-vivado}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build/group2_final_synth}"
PERF_LOG_DIR="${PERF_LOG_DIR:-$REPO_DIR/build/fpga/group2_perf_compare/manual_rerun}"
BITSTREAM_OVERRIDDEN=0
[[ -n "${BITSTREAM_PATH:-}" ]] && BITSTREAM_OVERRIDDEN=1
BITSTREAM_PATH="${BITSTREAM_PATH:-$BUILD_DIR/fpga/z2_course_io_ft232h_nucleo_group2/didactic-z2_course_io_ft232h_nucleo_group2.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit}"
OPENOCD_CFG="${OPENOCD_CFG:-$FPGA_DIR/utils/openocd-didactic-ft232h-z2.cfg}"
JTAG_TIMEOUT="${JTAG_TIMEOUT:-10}"

PROGRAM_TCL="$SCRIPT_DIR/program_z2_course_io_ft232h_nucleo.tcl"
PERF_RUNNER="$SCRIPT_DIR/run_group2_perf_compare.py"
RUN_STAMP="$(date +%F_%H%M%S)"
SETUP_LOG_DIR="${SETUP_LOG_DIR:-$REPO_DIR/build/fpga/group2_perf_compare/fpga_setup/$RUN_STAMP}"

REBUILD_BITSTREAM=0
SKIP_JTAG_CHECK=0
PERF_ARGS=()

usage() {
  cat <<USAGE
Usage: $(basename "$0") [wrapper options] [benchmark options]

Program the GROUP2 PYNQ-Z2 bitstream, verify the external FT232H JTAG link,
and run the CPU-only versus CPU+subsystem benchmark.

Wrapper options:
  --bitstream FILE         Bitstream to program. Default:
                           $BITSTREAM_PATH
  --build-dir DIR          FPGA build directory. Default: $BUILD_DIR
  --rebuild-bitstream      Rebuild the GROUP2 bitstream before programming.
  --vivado CMD             Vivado executable. Default: $VIVADO
  --vivado-settings FILE   Vivado settings64.sh. Default: $VIVADO_SETTINGS
  --jtag-timeout SEC       FT232H JTAG check timeout. Default: $JTAG_TIMEOUT
  --skip-jtag-check        Skip the FT232H-to-CPU connection check.
  -h, --help               Show this help.

All other options are forwarded to run_group2_perf_compare.py. The default
benchmark is equivalent to:
  --mode all --opt=-O3 --repetitions 7 --warmups 1
  --header-timeout 60 --header-attempts 5
  --openocd-retries 3 --openocd-timeout 15

Examples:
  ./fpga/scripts/run_group2_perf_with_bitstream.sh
  ./fpga/scripts/run_group2_perf_with_bitstream.sh --mode random
  ./fpga/scripts/run_group2_perf_with_bitstream.sh --rebuild-bitstream
  ./fpga/scripts/run_group2_perf_with_bitstream.sh --bitstream /path/to/design.bit

Environment equivalents:
  EDU_ENV, VIVADO_SETTINGS, VIVADO, BUILD_DIR, BITSTREAM_PATH, OPENOCD_CFG,
  JTAG_TIMEOUT, SETUP_LOG_DIR, PERF_LOG_DIR
USAGE
}

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bitstream)
      BITSTREAM_PATH="${2:?missing value for --bitstream}"
      BITSTREAM_OVERRIDDEN=1
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?missing value for --build-dir}"
      shift 2
      ;;
    --rebuild-bitstream)
      REBUILD_BITSTREAM=1
      shift
      ;;
    --vivado)
      VIVADO="${2:?missing value for --vivado}"
      shift 2
      ;;
    --vivado-settings)
      VIVADO_SETTINGS="${2:?missing value for --vivado-settings}"
      shift 2
      ;;
    --jtag-timeout)
      JTAG_TIMEOUT="${2:?missing value for --jtag-timeout}"
      shift 2
      ;;
    --skip-jtag-check)
      SKIP_JTAG_CHECK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      PERF_ARGS+=("$@")
      break
      ;;
    *)
      PERF_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$BITSTREAM_OVERRIDDEN" -eq 0 ]]; then
  BITSTREAM_PATH="$BUILD_DIR/fpga/z2_course_io_ft232h_nucleo_group2/didactic-z2_course_io_ft232h_nucleo_group2.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit"
fi

source_tool_environments() {
  set +u
  if [[ -f "$EDU_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$EDU_ENV"
  fi
  if [[ -f "$VIVADO_SETTINGS" ]]; then
    # shellcheck source=/dev/null
    source "$VIVADO_SETTINGS"
  fi
  set -u
}

build_bitstream_if_needed() {
  if [[ "$REBUILD_BITSTREAM" -eq 0 && -f "$BITSTREAM_PATH" ]]; then
    return
  fi

  if [[ "$REBUILD_BITSTREAM" -eq 0 ]]; then
    log "Bitstream is missing; building it first"
  else
    log "Rebuilding the GROUP2 bitstream"
  fi

  "$SCRIPT_DIR/build_group2_z2_bitstream.sh" \
    --vivado "$VIVADO" \
    --build-dir "$BUILD_DIR"
}

program_fpga() {
  local program_log="$SETUP_LOG_DIR/vivado_program.log"

  require_file "$BITSTREAM_PATH"
  require_file "$PROGRAM_TCL"

  log "Programming the PYNQ-Z2 FPGA"
  printf '[INFO] Bitstream : %s\n' "$BITSTREAM_PATH"
  printf '[INFO] Vivado log: %s\n' "$program_log"

  if ! (
    cd "$FPGA_DIR"
    BITSTREAM_PATH="$BITSTREAM_PATH" "$VIVADO" \
      -mode batch -nolog -nojournal -source "$PROGRAM_TCL"
  ) 2>&1 | tee "$program_log"; then
    die "Vivado could not program the FPGA. See $program_log"
  fi

  if ! grep -q '^DONE=1$' "$program_log"; then
    die "Vivado did not report DONE=1. See $program_log"
  fi
}

check_external_jtag() {
  local jtag_log="$SETUP_LOG_DIR/ft232h_jtag_check.log"

  if [[ "$SKIP_JTAG_CHECK" -eq 1 ]]; then
    log "Skipping the external FT232H JTAG check"
    return
  fi

  require_file "$OPENOCD_CFG"
  log "Checking that the external FT232H can see the Ibex CPU"
  printf '[INFO] JTAG log  : %s\n' "$jtag_log"

  if ! timeout --signal=KILL "${JTAG_TIMEOUT}s" \
    openocd -f "$OPENOCD_CFG" -c shutdown >"$jtag_log" 2>&1; then
    tail -n 30 "$jtag_log" >&2 || true
    echo >&2
    echo "ERROR: FPGA programming finished, but the FT232H cannot see the CPU." >&2
    echo "       Check FT232H power/GND and AD0, AD1, AD2, AD3, AD7 wiring." >&2
    echo "       The benchmark was not started. Full log: $jtag_log" >&2
    exit 1
  fi

  if ! grep -q 'Ready for Remote Connections' "$jtag_log"; then
    tail -n 30 "$jtag_log" >&2 || true
    die "OpenOCD ended without recognizing the CPU. See $jtag_log"
  fi

  printf '[OK] FT232H JTAG recognized the Ibex CPU.\n'
}

run_benchmark() {
  log "Running the fair CPU-only versus CPU+subsystem benchmark"
  exec "$PERF_RUNNER" \
    --repo "$REPO_DIR" \
    --mode all \
    --opt=-O3 \
    --log-dir "$PERF_LOG_DIR" \
    --repetitions 7 \
    --warmups 1 \
    --header-timeout 60 \
    --header-attempts 5 \
    --openocd-retries 3 \
    --openocd-timeout 15 \
    "${PERF_ARGS[@]}"
}

main() {
  mkdir -p "$SETUP_LOG_DIR"
  source_tool_environments

  require_cmd "$VIVADO"
  require_cmd openocd
  require_cmd timeout
  require_file "$PERF_RUNNER"

  build_bitstream_if_needed
  program_fpga
  check_external_jtag
  run_benchmark
}

main
