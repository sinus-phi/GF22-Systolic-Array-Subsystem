#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPGA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$FPGA_DIR/.." && pwd)"

PROJECT="z2_course_io_ft232h_nucleo_group2"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
VIVADO="${VIVADO:-vivado}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-}"
GUI=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Build the PYNQ-Z2 FPGA bitstream with the Ibex CPU and Group2 subsystem.

Options:
  --vivado CMD             Vivado executable. Default: $VIVADO
  --vivado-settings FILE   Optional Vivado settings64.sh to source first.
  --build-dir DIR          Build/output directory. Default: $BUILD_DIR
  --gui                    Launch the Vivado GUI flow instead of batch mode.
  -h, --help               Show this help.

Environment equivalents:
  VIVADO, VIVADO_SETTINGS, BUILD_DIR

Examples:
  ./fpga/scripts/build_group2_z2_bitstream.sh
  VIVADO_SETTINGS=/tools/Xilinx/2025.2/Vivado/settings64.sh ./fpga/scripts/build_group2_z2_bitstream.sh
  ./fpga/scripts/build_group2_z2_bitstream.sh --build-dir /tmp/group2_build
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vivado)
      VIVADO="${2:?missing value for --vivado}"
      shift 2
      ;;
    --vivado-settings)
      VIVADO_SETTINGS="${2:?missing value for --vivado-settings}"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="${2:?missing value for --build-dir}"
      shift 2
      ;;
    --gui)
      GUI=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"

log() {
  printf '[group2-synth] %s\n' "$*"
}

if [[ -n "$VIVADO_SETTINGS" ]]; then
  if [[ ! -f "$VIVADO_SETTINGS" ]]; then
    echo "ERROR: Vivado settings file not found: $VIVADO_SETTINGS" >&2
    exit 1
  fi
  log "Sourcing Vivado settings: $VIVADO_SETTINGS"
  set +u
  # shellcheck source=/dev/null
  source "$VIVADO_SETTINGS"
  set -u
fi

if ! command -v "$VIVADO" >/dev/null 2>&1; then
  echo "ERROR: Vivado executable not found: $VIVADO" >&2
  echo "       Put Vivado in PATH, pass --vivado, or set --vivado-settings." >&2
  exit 1
fi

if ! command -v bender >/dev/null 2>&1; then
  echo "ERROR: bender executable not found in PATH." >&2
  echo "       Set up the project/tool environment before running this script." >&2
  exit 1
fi

log "Repository : $REPO_DIR"
log "Project    : $PROJECT"
log "Build dir  : $BUILD_DIR"
log "Vivado     : $(command -v "$VIVADO")"

if [[ "$GUI" -eq 1 ]]; then
  log "Launching Vivado GUI flow"
  make -C "$FPGA_DIR" BUILD_DIR="$BUILD_DIR" VIVADO="$VIVADO" z2_course_io_ft232h_nucleo_group2_gui
  exit 0
fi

log "Running Vivado batch synthesis/implementation/bitstream"
make -C "$FPGA_DIR" BUILD_DIR="$BUILD_DIR" VIVADO="$VIVADO" z2_course_io_ft232h_nucleo_group2

BITSTREAM="$BUILD_DIR/fpga/$PROJECT/didactic-$PROJECT.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit"
BINFILE="$BUILD_DIR/fpga/$PROJECT/didactic-$PROJECT.runs/impl_1/DidacticZ2_FT232H_Nucleo.bin"
TIMING_RPT="$BUILD_DIR/fpga/logs/$PROJECT.timing.rpt"
UTIL_RPT="$BUILD_DIR/fpga/logs/$PROJECT.utilization.rpt"

if [[ ! -f "$BITSTREAM" ]]; then
  echo "ERROR: expected bitstream was not generated: $BITSTREAM" >&2
  exit 1
fi

log "Bitstream  : $BITSTREAM"
if [[ -f "$BINFILE" ]]; then
  log "Bin file   : $BINFILE"
fi
log "Timing rpt : $TIMING_RPT"
log "Util rpt   : $UTIL_RPT"
log "Done"
