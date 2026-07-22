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
export KFLOW_REPO_RUNTIME_PACKAGES="${KFLOW_REPO_RUNTIME_PACKAGES:-mfclkit=PacificCommunity/ofp-sam-mfclkit@d8df08e2b7891cdb93b395aa84e0dcf770e3b09f,mfclshiny=PacificCommunity/mfclshiny@0b9e1a1b365ac8fd339ed4d59da73d573121ee1f}"
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

runtime_retry_attempts() {
  local value="${KFLOW_RUNTIME_RETRY_ATTEMPTS:-3}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=3
  (( value < 1 )) && value=1
  (( value > 6 )) && value=6
  printf '%s' "$value"
}

runtime_retry_delay() {
  local value="${KFLOW_RUNTIME_RETRY_DELAY_SECONDS:-3}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=3
  (( value > 30 )) && value=30
  printf '%s' "$value"
}

runtime_git() {
  local askpass="$1" token="$2"
  shift 2
  if [[ -n "$token" ]]; then
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 KFLOW_GIT_ASKPASS_TOKEN="$token" git "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

clone_runtime_repo() {
  local repo="$1" src="$2" askpass="$3" token="$4"
  local attempts delay attempt status=1
  attempts="$(runtime_retry_attempts)"
  delay="$(runtime_retry_delay)"
  for ((attempt=1; attempt<=attempts; attempt++)); do
    rm -rf "$src"
    if runtime_git "$askpass" "$token" clone --quiet --depth 50 "https://github.com/${repo}.git" "$src"; then
      return 0
    else
      status=$?
    fi
    if (( attempt < attempts )); then
      echo "[kflow-runtime-update] Clone failed for ${repo}; retrying (${attempt}/${attempts})." >&2
      sleep "$delay"
    fi
  done
  return "$status"
}

checkout_runtime_ref() {
  local src="$1" ref="$2" askpass="$3" token="$4"
  local attempts delay attempt status=1
  if runtime_git "$askpass" "$token" -C "$src" checkout --quiet "$ref"; then
    return 0
  fi
  attempts="$(runtime_retry_attempts)"
  delay="$(runtime_retry_delay)"
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if runtime_git "$askpass" "$token" -C "$src" fetch --quiet --depth 1 origin "$ref" &&
       runtime_git "$askpass" "$token" -C "$src" checkout --quiet FETCH_HEAD; then
      return 0
    else
      status=$?
    fi
    if (( attempt < attempts )); then
      echo "[kflow-runtime-update] Fetch failed for ${ref}; retrying (${attempt}/${attempts})." >&2
      sleep "$delay"
    fi
  done
  return "$status"
}

use_installed_runtime_package() {
  local package="$1" requested="$2" details
  if details="$(KFLOW_RUNTIME_PACKAGE_NAME="$package" Rscript -e '
    p <- Sys.getenv("KFLOW_RUNTIME_PACKAGE_NAME")
    if (!requireNamespace(p, quietly = TRUE)) quit(save = "no", status = 1L)
    d <- packageDescription(p)
    sha <- d[["RemoteSha"]]
    label <- paste0(p, " ", as.character(packageVersion(p)))
    if (!is.null(sha) && nzchar(sha)) label <- paste0(label, " @", substr(sha, 1L, 12L))
    cat(label)
  ' 2>/dev/null)"; then
    echo "[kflow-runtime-update] WARNING: Could not fetch ${requested}; using image-installed ${details}." >&2
    return 0
  fi
  echo "[kflow-runtime-update] ERROR: Could not fetch ${requested}, and ${package} is not installed in the image." >&2
  return 1
}

runtime_ref_is_commit() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{40}$ ]]
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
  export R_LIBS="${R_LIBS_USER}${R_LIBS:+:${R_LIBS}}"

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
    fi

    if clone_runtime_repo "$repo" "$src" "$askpass" "$token"; then
      :
    else
      status=$?
      rm -f "$askpass"
      rm -rf "$src"
      if ! runtime_ref_is_commit "$ref" && use_installed_runtime_package "$package" "${repo}@${ref}"; then
        continue
      fi
      drop_runtime_tokens
      return "$status"
    fi
    if checkout_runtime_ref "$src" "$ref" "$askpass" "$token"; then
      :
    else
      status=$?
      rm -f "$askpass"
      rm -rf "$src"
      if ! runtime_ref_is_commit "$ref" && use_installed_runtime_package "$package" "${repo}@${ref}"; then
        continue
      fi
      drop_runtime_tokens
      return "$status"
    fi
    rm -f "$askpass"

    resolved_sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
    if runtime_ref_is_commit "$ref" && [[ "${resolved_sha,,}" != "${ref,,}" ]]; then
      echo "[kflow-runtime-update] ERROR: ${repo}@${ref} resolved to ${resolved_sha:-unknown}." >&2
      rm -rf "$src"
      drop_runtime_tokens
      return 1
    fi
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
