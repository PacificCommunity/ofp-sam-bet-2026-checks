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
export KFLOW_REPO_RUNTIME_PACKAGES="${KFLOW_REPO_RUNTIME_PACKAGES:-mfclkit=PacificCommunity/ofp-sam-mfclkit@main,mfclshiny=PacificCommunity/mfclshiny@main}"
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

install_runtime_repos() {
  local specs="${KFLOW_REPO_RUNTIME_PACKAGES:-}"
  case "$specs" in
    ""|0|false|FALSE|no|NO|off|OFF|none|NONE|skip|SKIP) return 0 ;;
  esac

  export R_LIBS_USER="${R_LIBS_USER:-${SCRIPT_DIR}/.R-library}"
  mkdir -p "$R_LIBS_USER" "${SCRIPT_DIR}/.kflow-runtime-cache"

  IFS=',' read -r -a parts <<< "$specs"
  local spec package repo_ref repo ref src token askpass status
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
        echo "[checks-runtime] using installed ${package}; KFLOW_REPO_RUNTIME_UPDATE=never"
        continue
      fi
    fi

    src="${SCRIPT_DIR}/.kflow-runtime-cache/${package}-src"
    rm -rf "$src"
    askpass=""
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
      echo "[checks-runtime] installing ${package} from ${repo}@${ref}"
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
      echo "[checks-runtime] installing ${package} from ${repo}@${ref}"
      git clone --quiet --depth 50 "https://github.com/${repo}.git" "$src"
      git -C "$src" checkout --quiet "$ref" || {
        git -C "$src" fetch --quiet --depth 1 origin "$ref"
        git -C "$src" checkout --quiet FETCH_HEAD
      }
    fi

    R CMD INSTALL -l "$R_LIBS_USER" "$src"
  done
}

install_runtime_repos

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"
Rscript R/run_check.R "$CHECK_TYPE"
