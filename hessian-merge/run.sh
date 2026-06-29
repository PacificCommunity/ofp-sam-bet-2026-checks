#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TASK_DIR}/.." && pwd)"
export CHECK_TYPE=hessian_merge
export OUTPUT_DIR="${OUTPUT_DIR:-${TASK_DIR}/outputs}"
export WORK_DIR="${WORK_DIR:-${TASK_DIR}/work}"
cd "$ROOT"
Rscript R/merge_hessian.R
