#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TASK_DIR}/.." && pwd)"
export CHECK_TYPE=selftest
export OUTPUT_DIR="${OUTPUT_DIR:-${TASK_DIR}/outputs}"
export WORK_DIR="${WORK_DIR:-${TASK_DIR}/work}"
export SELFTEST_RUNNER="${SELFTEST_RUNNER:-${CHECK_SELFTEST_SCRIPT:-runners/run_selftest.R}}"
export SELFTEST_RUNNER_REPO="${SELFTEST_RUNNER_REPO:-${CHECK_SELFTEST_REPO:-PacificCommunity/ofp-sam-2026-BET}}"
export SELFTEST_RUNNER_REF="${SELFTEST_RUNNER_REF:-${CHECK_SELFTEST_REF:-4R_sim}}"
export SELFTEST_RUN_REFIT="${SELFTEST_RUN_REFIT:-${CHECK_SELFTEST_RUN_REFIT:-false}}"
cd "$ROOT"
exec bash run.sh "$CHECK_TYPE"
