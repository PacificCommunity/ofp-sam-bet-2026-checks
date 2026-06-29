#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TASK_DIR}/.." && pwd)"
export CHECK_TYPE=selftest
export OUTPUT_DIR="${OUTPUT_DIR:-${TASK_DIR}/outputs}"
export WORK_DIR="${WORK_DIR:-${TASK_DIR}/work}"
if [[ -z "${SELFTEST_RUNNER:-}" && -n "${CHECK_SELFTEST_SCRIPT:-}" ]]; then
  export SELFTEST_RUNNER="$CHECK_SELFTEST_SCRIPT"
fi
if [[ -z "${SELFTEST_RUNNER_REPO:-}" && -n "${CHECK_SELFTEST_REPO:-}" ]]; then
  export SELFTEST_RUNNER_REPO="$CHECK_SELFTEST_REPO"
fi
if [[ -z "${SELFTEST_RUNNER_REF:-}" && -n "${CHECK_SELFTEST_REF:-}" ]]; then
  export SELFTEST_RUNNER_REF="$CHECK_SELFTEST_REF"
fi
export SELFTEST_RUN_REFIT="${SELFTEST_RUN_REFIT:-${CHECK_SELFTEST_RUN_REFIT:-false}}"
cd "$ROOT"
exec bash run.sh "$CHECK_TYPE"
