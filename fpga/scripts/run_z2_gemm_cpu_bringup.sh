#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPGA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$FPGA_DIR/.." && pwd)"

EDU_ENV="${EDU_ENV:-/home/sinus-phi/Edu4Chip/env.sh}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/home/sinus-phi/Xilinx/2025.2/Vivado/settings64.sh}"
UART_DEV="${UART_DEV:-/dev/ttyACM0}"
UART_BAUD="${UART_BAUD:-9600}"
TESTCASE="${TESTCASE:-gemm_cpu}"
ELF_PATH="${ELF_PATH:-$REPO_DIR/build/fpga/sw/$TESTCASE.elf}"

BITSTREAM_PATH="$REPO_DIR/build/fpga/z2_course_io_ft232h_nucleo/didactic-z2_course_io_ft232h_nucleo.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit"
OPENOCD_CFG="$FPGA_DIR/utils/openocd-didactic-ft232h-z2.cfg"
PROGRAM_TCL="$FPGA_DIR/scripts/program_z2_course_io_ft232h_nucleo.tcl"

SKIP_NUCLEO=0
SKIP_FPGA=0
SKIP_BUILD=0
NO_UART_TERMINAL=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --skip-nucleo        Do not rebuild/flash the Nucleo UART bridge.
  --skip-fpga          Do not program the PYNQ-Z2 bitstream.
  --skip-build         Do not rebuild the RISC-V GEMM ELF.
  --no-uart-terminal   Do not open a separate UART terminal.
  --uart-dev DEV       UART device for Nucleo ST-LINK VCP. Default: $UART_DEV
  --elf PATH           ELF to load over FT232H JTAG. Default: $ELF_PATH
  -h, --help           Show this help.

Environment overrides:
  EDU_ENV, VIVADO_SETTINGS, UART_DEV, UART_BAUD, TESTCASE, ELF_PATH
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-nucleo)
      SKIP_NUCLEO=1
      shift
      ;;
    --skip-fpga)
      SKIP_FPGA=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --no-uart-terminal)
      NO_UART_TERMINAL=1
      shift
      ;;
    --uart-dev)
      UART_DEV="${2:?missing value for --uart-dev}"
      shift 2
      ;;
    --elf)
      ELF_PATH="${2:?missing value for --elf}"
      shift 2
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

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "ERROR: required file not found: $1" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: command not found: $1" >&2
    exit 1
  fi
}

shell_quote() {
  printf '%q' "$1"
}

source_env() {
  require_file "$EDU_ENV"
  require_file "$VIVADO_SETTINGS"

  # shellcheck source=/dev/null
  source "$EDU_ENV"
  # shellcheck source=/dev/null
  source "$VIVADO_SETTINGS"
}

build_gemm_elf() {
  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    log "Skipping RISC-V GEMM ELF rebuild"
    return
  fi

  log "Building RISC-V CPU-only GEMM ELF"
  (
    cd "$FPGA_DIR/sw"
    make TESTCASE="$TESTCASE" \
      CFLAGS="-mabi=ilp32 -Os -g -ffunction-sections -fdata-sections -Icommon/" \
      test
  )
}

flash_nucleo() {
  if [[ "$SKIP_NUCLEO" -eq 1 ]]; then
    log "Skipping Nucleo UART bridge flash"
    return
  fi

  log "Building and flashing Nucleo F411RE UART bridge"
  (
    cd "$FPGA_DIR"
    make -f Makefile.z2_course_io_ft232h_nucleo nucleo_bridge
    make -f Makefile.z2_course_io_ft232h_nucleo flash_nucleo_bridge
  )
}

program_fpga() {
  if [[ "$SKIP_FPGA" -eq 1 ]]; then
    log "Skipping PYNQ-Z2 bitstream programming"
    return
  fi

  require_file "$BITSTREAM_PATH"
  require_file "$PROGRAM_TCL"

  log "Programming PYNQ-Z2 FPGA bitstream"
  (
    cd "$FPGA_DIR"
    vivado -mode batch -nolog -nojournal -source "$PROGRAM_TCL"
  )
}

make_uart_monitor_script() {
  local monitor_script
  monitor_script="$(mktemp /tmp/didactic_uart_monitor.XXXXXX.sh)"

  cat > "$monitor_script" <<'MONITOR'
#!/usr/bin/env bash
set -euo pipefail

echo "[UART] Device: ${UART_DEV} @ ${UART_BAUD} 8N1"
echo "[UART] Waiting for Nucleo banner and GEMM output."
echo "[UART] Close this window with Ctrl-C when finished."
echo

if [[ ! -e "$UART_DEV" ]]; then
  echo "[UART] ERROR: device not found: $UART_DEV" >&2
  read -r -p "Press Enter to close..." _
  exit 1
fi

stty -F "$UART_DEV" "$UART_BAUD" cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo
cat -v "$UART_DEV"
MONITOR

  chmod +x "$monitor_script"
  echo "$monitor_script"
}

launch_uart_terminal() {
  if [[ "$NO_UART_TERMINAL" -eq 1 ]]; then
    log "Skipping separate UART terminal"
    return
  fi

  local monitor_script cmd
  monitor_script="$(make_uart_monitor_script)"
  cmd="UART_DEV=$(shell_quote "$UART_DEV") UART_BAUD=$(shell_quote "$UART_BAUD") bash $(shell_quote "$monitor_script")"

  log "Opening UART monitor in a separate terminal: $UART_DEV"
  if [[ -n "${DISPLAY:-}" ]] && command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal --title="Didactic UART GEMM" -- bash -lc "$cmd"
  elif [[ -n "${DISPLAY:-}" ]] && command -v xterm >/dev/null 2>&1; then
    xterm -T "Didactic UART GEMM" -e bash -lc "$cmd" &
  elif [[ -n "${DISPLAY:-}" ]] && command -v konsole >/dev/null 2>&1; then
    konsole --new-tab -p tabtitle="Didactic UART GEMM" -e bash -lc "$cmd" &
  else
    echo "ERROR: no supported graphical terminal found." >&2
    echo "Run with --no-uart-terminal and manually monitor:" >&2
    echo "  stty -F $(shell_quote "$UART_DEV") $UART_BAUD cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo" >&2
    echo "  cat -v $(shell_quote "$UART_DEV")" >&2
    exit 1
  fi

  sleep 2
}

reset_nucleo_for_banner() {
  if [[ "$NO_UART_TERMINAL" -eq 1 ]]; then
    return
  fi

  log "Resetting Nucleo so the UART monitor catches the bridge banner"
  openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
    -c "init" \
    -c "reset run" \
    -c "shutdown"
  sleep 1
}

load_and_run_elf() {
  require_file "$ELF_PATH"
  require_file "$OPENOCD_CFG"

  log "Loading and running ELF over FT232H JTAG"
  (
    cd "$FPGA_DIR"
    openocd -f "$OPENOCD_CFG" \
      -c "load_image $ELF_PATH" \
      -c "resume 0x01000000" \
      -c "sleep 5000" \
      -c "shutdown"
  )
}

main() {
  log "Starting PYNQ-Z2 + FT232H + Nucleo CPU-only GEMM bring-up"
  source_env

  require_cmd make
  require_cmd openocd
  require_cmd vivado

  if [[ ! -e "$UART_DEV" ]]; then
    echo "WARNING: UART device does not exist yet: $UART_DEV" >&2
    echo "         Check that the Nucleo ST-LINK USB is connected." >&2
  fi

  flash_nucleo
  program_fpga
  build_gemm_elf
  launch_uart_terminal
  reset_nucleo_for_banner
  load_and_run_elf

  log "Done. Check the UART terminal for GEMM CPU TEST PASS."
}

main "$@"
