#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FPGA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$FPGA_DIR/.." && pwd)"

EDU_ENV="${EDU_ENV:-/home/sinus-phi/Edu4Chip/env.sh}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/home/sinus-phi/Xilinx/2025.2/Vivado/settings64.sh}"
UART_DEV="${UART_DEV:-/dev/ttyACM0}"
UART_BAUD="${UART_BAUD:-9600}"
TESTCASES="${TESTCASES:-ss2_smoke ss2_gemm ss2_header_sweep}"
UART_TIMEOUT="${UART_TIMEOUT:-25}"
ELF_WAIT_MS="${ELF_WAIT_MS:-12000}"
HEADER_SWEEP_ARGS="${HEADER_SWEEP_ARGS:-}"
RUN_STAMP="${RUN_STAMP:-$(date +%F_%H%M%S)}"
LOG_DIR="${LOG_DIR:-$REPO_DIR/build/fpga/ss2_hw_workflow/$RUN_STAMP}"

BITSTREAM_PATH="$REPO_DIR/build/fpga/z2_course_io_ft232h_nucleo/didactic-z2_course_io_ft232h_nucleo.runs/impl_1/DidacticZ2_FT232H_Nucleo.bit"
OPENOCD_CFG="$FPGA_DIR/utils/openocd-didactic-ft232h-z2.cfg"
PROGRAM_TCL="$FPGA_DIR/scripts/program_z2_course_io_ft232h_nucleo.tcl"
UART_CAPTURE="$SCRIPT_DIR/uart_capture_until.py"
HEADER_SWEEP="$SCRIPT_DIR/run_ss2_header_sweep.py"

SKIP_NUCLEO=0
SKIP_FPGA=0
SKIP_BUILD=0
REBUILD_BITSTREAM=0
FORCE_UART=0
CUSTOM_ELF=""
CUSTOM_NAME=""

PASS_REGEX="${PASS_REGEX:-SS2 .* TEST PASS|GEMM CPU TEST PASS|HEADER_DONE,.*PASS|ALL_HEADERS_FINAL,.*PASS}"
FAIL_REGEX="${FAIL_REGEX:-SS2 .* TEST FAIL|GEMM CPU TEST FAIL|HEADER_DONE,.*FAIL|ALL_HEADERS_FINAL,.*FAIL}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Fresh-start SS2 hardware workflow for PYNQ-Z2 + FT232H + Nucleo F411RE.

Default flow:
  1. Source Edu4Chip and Vivado environments.
  2. Build/flash the Nucleo UART bridge.
  3. Program the PYNQ-Z2 FPGA bitstream.
  4. Build each RISC-V testcase ELF.
  5. Capture UART live, load ELF over FT232H JTAG, and save logs.

Options:
  --testcases "A B"      Space-separated fpga/sw testcase names.
                         Default: "$TESTCASES"
  --elf PATH             Run one prebuilt ELF instead of building TESTCASES.
  --name NAME            Display/log name for --elf mode.
  --skip-nucleo          Do not rebuild/flash Nucleo UART bridge.
  --skip-fpga            Do not program PYNQ-Z2 bitstream.
  --skip-build           Do not rebuild RISC-V testcases.
  --rebuild-bitstream    Re-run Vivado implementation before programming.
  --force-uart           Kill processes currently holding UART_DEV.
  --uart-dev DEV         UART device. Default: $UART_DEV
  --uart-baud BAUD       UART baud. Default: $UART_BAUD
  --uart-timeout SEC     UART capture timeout per ELF. Default: $UART_TIMEOUT
  --elf-wait-ms MS       OpenOCD sleep after resume. Default: $ELF_WAIT_MS
  --log-dir DIR          Log output directory. Default: $LOG_DIR
  -h, --help             Show this help.

Useful examples:
  $(basename "$0")
  $(basename "$0") --testcases "ss2_smoke ss2_gemm"
  $(basename "$0") --testcases "ss2_smoke ss2_gemm ss2_header_sweep"
  $(basename "$0") --skip-nucleo --skip-fpga --testcases "ss2_gemm"
  $(basename "$0") --elf ../build/fpga/sw/ss2_smoke.elf --name ss2_smoke

Environment overrides:
  EDU_ENV, VIVADO_SETTINGS, UART_DEV, UART_BAUD, TESTCASES, UART_TIMEOUT,
  ELF_WAIT_MS, LOG_DIR, PASS_REGEX, FAIL_REGEX, HEADER_SWEEP_ARGS

Note:
  UART is printed in real time.

  ss2_header_sweep is a special hardware testcase. It does not build a single
  fpga/sw ELF. Instead, it runs sw/gemm/include/array_mode*.h one header at a
  time by generating small 8x8x8 tile ELFs under LOG_DIR and prints one
  HEADER_DONE line whenever a full header finishes.

  To limit or tweak the header sweep, pass options through HEADER_SWEEP_ARGS,
  for example:
    HEADER_SWEEP_ARGS="--limit-headers 1" $(basename "$0") --testcases "ss2_header_sweep"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --testcases)
      TESTCASES="${2:?missing value for --testcases}"
      shift 2
      ;;
    --elf)
      CUSTOM_ELF="${2:?missing value for --elf}"
      shift 2
      ;;
    --name)
      CUSTOM_NAME="${2:?missing value for --name}"
      shift 2
      ;;
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
    --rebuild-bitstream)
      REBUILD_BITSTREAM=1
      shift
      ;;
    --force-uart)
      FORCE_UART=1
      shift
      ;;
    --uart-dev)
      UART_DEV="${2:?missing value for --uart-dev}"
      shift 2
      ;;
    --uart-baud)
      UART_BAUD="${2:?missing value for --uart-baud}"
      shift 2
      ;;
    --uart-timeout)
      UART_TIMEOUT="${2:?missing value for --uart-timeout}"
      shift 2
      ;;
    --elf-wait-ms)
      ELF_WAIT_MS="${2:?missing value for --elf-wait-ms}"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="${2:?missing value for --log-dir}"
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

source_env() {
  require_file "$EDU_ENV"
  require_file "$VIVADO_SETTINGS"

  # Xilinx/Edu4Chip setup scripts reference optional environment variables.
  # Keep strict mode for our code, but do not let nounset break vendor setup.
  set +u
  # shellcheck source=/dev/null
  source "$EDU_ENV"
  # shellcheck source=/dev/null
  source "$VIVADO_SETTINGS"
  set -u
}

check_uart_free() {
  if [[ ! -e "$UART_DEV" ]]; then
    echo "ERROR: UART device does not exist: $UART_DEV" >&2
    exit 1
  fi

  local pids
  pids="$(fuser "$UART_DEV" 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  if [[ "$FORCE_UART" -eq 1 ]]; then
    log "Killing stale UART users on $UART_DEV: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 0.5
  else
    echo "ERROR: UART device is busy: $UART_DEV" >&2
    echo "       PIDs: $pids" >&2
    echo "       Close the monitor or rerun with --force-uart." >&2
    exit 1
  fi
}

build_nucleo_bridge() {
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

ensure_bitstream() {
  if [[ "$SKIP_FPGA" -eq 1 ]]; then
    log "Skipping PYNQ-Z2 bitstream programming"
    return
  fi

  if [[ "$REBUILD_BITSTREAM" -eq 1 || ! -f "$BITSTREAM_PATH" ]]; then
    log "Building PYNQ-Z2 SS2 bitstream"
    (
      cd "$FPGA_DIR"
      make -f Makefile.z2_course_io_ft232h_nucleo all_xilinx
    )
  fi
}

program_fpga() {
  if [[ "$SKIP_FPGA" -eq 1 ]]; then
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

build_testcase() {
  local testcase="$1"

  if [[ "$SKIP_BUILD" -eq 1 ]]; then
    log "Skipping RISC-V rebuild for $testcase"
    return
  fi

  log "Building RISC-V ELF: $testcase"
  (
    cd "$FPGA_DIR/sw"
    make TESTCASE="$testcase" test
  )
}

reset_nucleo_for_banner() {
  log "Resetting Nucleo UART bridge"
  openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
    -c "init" \
    -c "reset run" \
    -c "shutdown" >/dev/null
  sleep 0.5
}

halt_riscv_quietly() {
  openocd -f "$OPENOCD_CFG" \
    -c "halt" \
    -c "shutdown" >/dev/null 2>&1 || true
}

load_and_run_elf() {
  local elf_path="$1"
  local openocd_log="$2"

  require_file "$elf_path"
  require_file "$OPENOCD_CFG"

  (
    cd "$FPGA_DIR"
    openocd -f "$OPENOCD_CFG" \
      -c "halt" \
      -c "load_image $elf_path" \
      -c "resume 0x01000000" \
      -c "sleep $ELF_WAIT_MS" \
      -c "shutdown"
  ) >"$openocd_log" 2>&1
}

run_one_elf() {
  local name="$1"
  local elf_path="$2"
  local uart_log="$LOG_DIR/${name}.uart.log"
  local openocd_log="$LOG_DIR/${name}.openocd.log"
  local uart_rc=0

  log "Running $name over FT232H JTAG"
  printf '[INFO] ELF       : %s\n' "$elf_path"
  printf '[INFO] UART log  : %s\n' "$uart_log"
  printf '[INFO] OpenOCD log: %s\n' "$openocd_log"

  halt_riscv_quietly

  "$UART_CAPTURE" \
    --dev "$UART_DEV" \
    --baud "$UART_BAUD" \
    --timeout "$UART_TIMEOUT" \
    --log "$uart_log" \
    --pass-regex "$PASS_REGEX" \
    --fail-regex "$FAIL_REGEX" &
  local uart_pid=$!

  sleep 0.4
  reset_nucleo_for_banner
  sleep 0.6

  if ! load_and_run_elf "$elf_path" "$openocd_log"; then
    kill "$uart_pid" 2>/dev/null || true
    wait "$uart_pid" 2>/dev/null || true
    echo "ERROR: OpenOCD failed for $name. See $openocd_log" >&2
    return 1
  fi

  set +e
  wait "$uart_pid"
  uart_rc=$?
  set -e

  case "$uart_rc" in
    0)
      log "$name PASS"
      ;;
    2)
      echo "ERROR: $name reported FAIL on UART. See $uart_log" >&2
      return 2
      ;;
    124)
      echo "ERROR: UART timeout while running $name. See $uart_log" >&2
      return 124
      ;;
    *)
      echo "ERROR: UART capture exited with code $uart_rc for $name" >&2
      return "$uart_rc"
      ;;
  esac
}

run_header_sweep() {
  log "Running SS2 full-header sweep one tile ELF at a time"
  require_file "$HEADER_SWEEP"

  local extra_args=()
  if [[ -n "$HEADER_SWEEP_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra_args=($HEADER_SWEEP_ARGS)
  fi

  "$HEADER_SWEEP" \
    --repo "$REPO_DIR" \
    --uart-dev "$UART_DEV" \
    --uart-baud "$UART_BAUD" \
    --tile-timeout "$UART_TIMEOUT" \
    --elf-wait-ms "$ELF_WAIT_MS" \
    --openocd-cfg "$OPENOCD_CFG" \
    --uart-capture "$UART_CAPTURE" \
    --log-dir "$LOG_DIR/ss2_header_sweep" \
    "${extra_args[@]}"
}

main() {
  mkdir -p "$LOG_DIR"

  log "Starting SS2 hardware workflow"
  printf '[INFO] Repo     : %s\n' "$REPO_DIR"
  printf '[INFO] Log dir  : %s\n' "$LOG_DIR"
  printf '[INFO] UART     : %s @ %s\n' "$UART_DEV" "$UART_BAUD"

  source_env

  require_cmd make
  require_cmd openocd
  require_cmd vivado
  require_cmd python3
  require_file "$UART_CAPTURE"
  require_file "$HEADER_SWEEP"

  check_uart_free
  build_nucleo_bridge
  ensure_bitstream
  program_fpga

  if [[ -n "$CUSTOM_ELF" ]]; then
    local name="$CUSTOM_NAME"
    if [[ -z "$name" ]]; then
      name="$(basename "$CUSTOM_ELF" .elf)"
    fi
    run_one_elf "$name" "$CUSTOM_ELF"
  else
    local testcase
    for testcase in $TESTCASES; do
      if [[ "$testcase" == "ss2_header_sweep" ]]; then
        run_header_sweep
      else
        build_testcase "$testcase"
        run_one_elf "$testcase" "$REPO_DIR/build/fpga/sw/$testcase.elf"
      fi
    done
  fi

  log "SS2 hardware workflow completed"
  printf '[INFO] Logs saved under: %s\n' "$LOG_DIR"
}

main "$@"
