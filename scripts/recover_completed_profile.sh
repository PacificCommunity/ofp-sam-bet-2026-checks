#!/usr/bin/env bash
set -euo pipefail

input_root="${KFLOW_INPUT_DIR:-${INPUT_DIR:-/inputs}}"
output_root="${KFLOW_OUTPUT_DIR:-${OUTPUT_DIR:-outputs}}"
source_job_id="${RECOVER_PROFILE_SOURCE_JOB_ID:-}"
expected_values="${RECOVER_PROFILE_VALUES:-}"

if [[ -n "$source_job_id" && -d "$input_root/$source_job_id" ]]; then
  source_root="$input_root/$source_job_id"
else
  mapfile -t candidates < <(
    find "$input_root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort
  )
  if (( ${#candidates[@]} != 1 )); then
    echo "Expected exactly one recovered profile input under $input_root; found ${#candidates[@]}." >&2
    exit 1
  fi
  source_root="${candidates[0]}"
fi

summary_file="$(
  find "$source_root" -path '*/checks/profile/*/check-summary.csv' -type f -print -quit
)"
status_file="$(
  find "$source_root" -path '*/checks/profile/*/check-unit-status.csv' -type f -print -quit
)"
if [[ -z "$summary_file" || -z "$status_file" ]]; then
  echo "Recovered profile archive is missing its check summary or unit status." >&2
  exit 1
fi

python3 - "$summary_file" "$status_file" "$expected_values" <<'PY'
import csv
import math
import sys

summary_file, status_file, expected_raw = sys.argv[1:]
with open(summary_file, newline="", encoding="utf-8") as handle:
    summaries = list(csv.DictReader(handle))
if len(summaries) != 1:
    raise SystemExit(f"Expected one profile summary row; found {len(summaries)}.")
summary = summaries[0]
if int(summary.get("n_failed", "-1")) != 0:
    raise SystemExit(f"Recovered profile reports failed units: {summary.get('n_failed')}.")
if str(summary.get("all_required_units_successful", "")).strip().upper() != "TRUE":
    raise SystemExit("Recovered profile does not report all required units successful.")

with open(status_file, newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))
if not rows:
    raise SystemExit("Recovered profile unit status is empty.")
bad = [
    row for row in rows
    if str(row.get("success", "")).strip().upper() != "TRUE"
    or str(row.get("point_valid", "")).strip().upper() != "TRUE"
    or str(row.get("converged", "")).strip().upper() != "TRUE"
]
if bad:
    raise SystemExit(f"Recovered profile contains {len(bad)} unsuccessful point(s).")

expected = sorted(float(value) for value in expected_raw.replace(",", " ").split())
actual = sorted(float(row["scalar"]) for row in rows)
if expected and (
    len(expected) != len(actual)
    or any(not math.isclose(a, b, abs_tol=1e-9) for a, b in zip(expected, actual))
):
    raise SystemExit(f"Recovered scalar grid {actual} does not match expected grid {expected}.")
print(f"Validated recovered profile: {len(rows)}/{len(rows)} points successful; grid={actual}")
PY

mkdir -p "$output_root"
cp -a "$source_root"/. "$output_root"/
printf '%s\n' \
  'schema=ofp-sam.recovered-profile.v1' \
  "source_job_id=${source_job_id:-$(basename "$source_root")}" \
  "expected_values=${expected_values}" \
  "summary_file=${summary_file#"$source_root"/}" \
  "status_file=${status_file#"$source_root"/}" \
  > "$output_root/recovered-profile-manifest.txt"

echo "Recovered completed profile archive without rerunning MFCL."
