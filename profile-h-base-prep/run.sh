#!/usr/bin/env bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TASK_DIR}/.." && pwd)"
export CHECK_TYPE=profile
export PROFILE_PARALLEL_MODE=h-base
export PROFILE_HBASE_ENABLED=true
export PROFILE_HBASE_ROLE=prep
export OUTPUT_DIR="${OUTPUT_DIR:-${TASK_DIR}/outputs}"
export WORK_DIR="${WORK_DIR:-${TASK_DIR}/work}"
cd "$ROOT"
exec bash run.sh "$CHECK_TYPE"
