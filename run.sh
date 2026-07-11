#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CHECK_TYPE="${1:-${CHECK_TYPE:-}}"
if [[ -z "$CHECK_TYPE" ]]; then
  CHECK_TYPE="$(basename "$(pwd)")"
fi
export CHECK_TYPE

export OUTPUT_DIR="${OUTPUT_DIR:-outputs}"
export WORK_DIR="${WORK_DIR:-work}"
export PROGRAM_PATH="${PROGRAM_PATH:-/home/mfcl/mfclo64}"
export KFLOW_RUNTIME_UPDATE="${KFLOW_RUNTIME_UPDATE:-always}"
export TUNA_FLOW_RUNTIME_UPDATE="${TUNA_FLOW_RUNTIME_UPDATE:-always}"
export KFLOW_RUNTIME_PACKAGES="${KFLOW_RUNTIME_PACKAGES:-none}"
export KFLOW_REPO_RUNTIME_PACKAGES="${KFLOW_REPO_RUNTIME_PACKAGES:-mfclkit=PacificCommunity/ofp-sam-mfclkit@c4e257a4d2c01e42ac151f01ed79063cdae86ef5,mfclshiny=PacificCommunity/mfclshiny@65c416d6b4b555c95772a99028fbb47e00cfce82}"
export KFLOW_REPO_RUNTIME_UPDATE="${KFLOW_REPO_RUNTIME_UPDATE:-always}"

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON|always|ALWAYS) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_updates_disabled() {
  case "${KFLOW_REPO_RUNTIME_UPDATE:-auto}" in
    never|NEVER) return 0 ;;
    *) return 1 ;;
  esac
}

first_token() {
  local name
  for name in GITHUB_PAT GIT_PAT GH_TOKEN GITHUB_TOKEN KFLOW_GITHUB_TOKEN KFLOW_PERSONAL_TOKEN; do
    if [[ -n "${!name:-}" ]]; then
      printf '%s' "${!name}"
      return 0
    fi
  done
  return 1
}

drop_runtime_tokens() {
  unset GIT_PAT GITHUB_PAT GITHUB_TOKEN GH_TOKEN KFLOW_GITHUB_TOKEN KFLOW_PERSONAL_TOKEN
}

install_runtime_repos() {
  local specs="${KFLOW_REPO_RUNTIME_PACKAGES:-}"
  case "$specs" in
    ""|0|false|FALSE|no|NO|off|OFF|none|NONE|skip|SKIP) return 0 ;;
  esac

  export R_LIBS_USER="${R_LIBS_USER:-${SCRIPT_DIR}/.R-library}"
  mkdir -p "$R_LIBS_USER" "${SCRIPT_DIR}/.kflow-runtime-cache"

  IFS=',' read -r -a parts <<< "$specs"
  local spec package repo_ref repo ref src token askpass status resolved_sha
  token="$(first_token || true)"

  for spec in "${parts[@]}"; do
    spec="${spec#"${spec%%[![:space:]]*}"}"
    spec="${spec%"${spec##*[![:space:]]}"}"
    [[ -z "$spec" || "$spec" != *=* ]] && continue
    package="${spec%%=*}"
    repo_ref="${spec#*=}"
    repo="${repo_ref%@*}"
    ref="${repo_ref##*@}"
    if [[ "$repo_ref" != *@* ]]; then
      ref="main"
    fi

    if runtime_updates_disabled; then
      if Rscript -e "quit(save='no', status=ifelse(requireNamespace('${package}', quietly=TRUE), 0L, 1L))"; then
        echo "[kflow-runtime-update] Using installed ${package}; KFLOW_REPO_RUNTIME_UPDATE=never."
        continue
      fi
    fi

    src="${SCRIPT_DIR}/.kflow-runtime-cache/${package}-src"
    rm -rf "$src"
    askpass=""
    echo "[kflow-runtime-update] Installing/updating runtime package ${package} from ${repo}@${ref}."
    if [[ -n "$token" ]]; then
      askpass="$(mktemp)"
      cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *) printf '%s\n' "$KFLOW_GIT_ASKPASS_TOKEN" ;;
esac
ASKPASS
      chmod 700 "$askpass"
      GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 KFLOW_GIT_ASKPASS_TOKEN="$token" \
        git clone --quiet --depth 50 "https://github.com/${repo}.git" "$src" || {
          status=$?
          rm -f "$askpass"
          return "$status"
        }
      GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 KFLOW_GIT_ASKPASS_TOKEN="$token" \
        git -C "$src" checkout --quiet "$ref" || {
          GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 KFLOW_GIT_ASKPASS_TOKEN="$token" \
            git -C "$src" fetch --quiet --depth 1 origin "$ref"
          GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 KFLOW_GIT_ASKPASS_TOKEN="$token" \
            git -C "$src" checkout --quiet FETCH_HEAD
        }
      rm -f "$askpass"
    else
      git clone --quiet --depth 50 "https://github.com/${repo}.git" "$src"
      git -C "$src" checkout --quiet "$ref" || {
        git -C "$src" fetch --quiet --depth 1 origin "$ref"
        git -C "$src" checkout --quiet FETCH_HEAD
      }
    fi

    resolved_sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$resolved_sha" ]]; then
      echo "[kflow-runtime-update] Resolved ${repo}@${ref} to ${resolved_sha:0:12}."
    fi
    R CMD INSTALL -l "$R_LIBS_USER" "$src"
    if [[ -n "$resolved_sha" ]]; then
      echo "[kflow-runtime-update] Installed ${package} at ${resolved_sha:0:12}."
    else
      echo "[kflow-runtime-update] Installed ${package}."
    fi
  done
  drop_runtime_tokens
}

install_runtime_repos

if [[ "$CHECK_TYPE" == "selftest" ]]; then
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
  if [[ -n "${SELFTEST_RUNNER:-}" ]]; then
    echo "[checks] selftest runner override: ${SELFTEST_RUNNER} (${SELFTEST_RUNNER_REPO:-local}@${SELFTEST_RUNNER_REF:-})"
  else
    echo "[checks] selftest runner: mfclkit bundled native runner"
  fi
fi

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
case "$CHECK_TYPE" in
  attach|attach_checks|attach-checks)
    Rscript R/attach_checks.R
    ;;
  model_bundle|model-bundle|bundle|export-bundle|mfcl-bundle)
    Rscript R/export_model_bundle.R
    ;;
  hessian_merge|hessian-merge)
    Rscript R/merge_hessian.R
    ;;
  *-merge|*_merge)
    Rscript R/merge_check.R
    ;;
  *)
    Rscript R/run_check.R "$CHECK_TYPE"
    ;;
esac
