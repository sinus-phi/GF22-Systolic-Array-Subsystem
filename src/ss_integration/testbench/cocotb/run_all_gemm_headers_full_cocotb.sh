#!/usr/bin/env bash
set -euo pipefail

# Run every sw/gemm/include/array_mode*.h header as a full GEMM against the
# APB-visible subsystem RTL.
#
# Optional controls:
#   SIM=verilator
#   ALL_HEADERS_GLOB='array_mode*.h'
#   ALL_HEADERS_SUMMARY_VALUES=8
#   ALL_HEADERS_PRINT_ALL_VALUES=1

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
echo "HeaderGlob : ${ALL_HEADERS_GLOB:-array_mode*.h}"

"${PYTHON_BIN}" src/ss_integration/testbench/cocotb/test_all_gemm_headers_full_cocotb.py
