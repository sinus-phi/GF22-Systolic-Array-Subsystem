#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EDU_ENV="${EDU_ENV:-/home/sinus-phi/Edu4Chip/env.sh}"

if [[ -f "$EDU_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$EDU_ENV"
fi

exec "$SCRIPT_DIR/run_group2_perf_compare.py" \
  --repo "$REPO_DIR" \
  --mode random \
  "$@"
