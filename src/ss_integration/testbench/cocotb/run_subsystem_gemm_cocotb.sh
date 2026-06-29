#!/usr/bin/env bash
set -euo pipefail

# Run from anywhere inside the repository:
#   ./src/ss_integration/testbench/cocotb/run_subsystem_gemm_cocotb.sh
#
# Default simulator selection follows the practical local setup:
#   1. Use SIM from the environment when provided.
#   2. Prefer Verilator when available.
#   3. Fall back to Icarus when iverilog/vvp are available.
#
# Optional randomized GEMM-header controls:
#   GEMM_HEADER=array_mode9_16b_8b_32_32_32_random.h
#   GEMM_RANDOM_SEED=1234
#   GEMM_RANDOM_HEADERS=2
#   GEMM_RANDOM_CASES=2
#
# Optional full 32x32x32 mode5 GEMM:
#   RUN_FULL_GEMM_MODE5=1
#   FULL_GEMM_SUMMARY_VALUES=64

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../../.." && pwd)"

cd "${REPO_ROOT}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "ERROR: ${PYTHON_BIN} was not found. Set PYTHON_BIN or install python3." >&2
  exit 1
fi

if ! "${PYTHON_BIN}" - <<'PY' >/dev/null 2>&1
import cocotb
PY
then
  echo "cocotb is not installed for ${PYTHON_BIN}; installing with --user..."
  "${PYTHON_BIN}" -m pip install --user -r "${SCRIPT_DIR}/requirements.txt"
fi

if [[ -z "${SIM:-}" ]]; then
  if command -v verilator >/dev/null 2>&1; then
    export SIM=verilator
  elif command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
    export SIM=icarus
  else
    echo "ERROR: no supported simulator found. Install Verilator or Icarus Verilog." >&2
    exit 1
  fi
fi

echo "Repository : ${REPO_ROOT}"
echo "Python     : $(${PYTHON_BIN} --version)"
echo "Simulator  : ${SIM}"

"${PYTHON_BIN}" src/ss_integration/testbench/cocotb/run_subsystem_gemm_cocotb.py
