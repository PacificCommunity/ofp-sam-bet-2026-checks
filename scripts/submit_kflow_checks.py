#!/usr/bin/env python3
"""Submit independent Kflow check jobs."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.error
import urllib.request
from typing import Any


MERGE_CHECKS = {
    "jitter": "jitter-merge",
    "retro": "retro-merge",
    "selftest": "selftest-merge",
    "profile": "profile-merge",
    "hessian": "hessian-merge",
}

DEFAULT_RUNTIME_PACKAGES = (
    "mfclkit=PacificCommunity/ofp-sam-mfclkit@main,"
    "mfclshiny=PacificCommunity/mfclshiny@2dfa656dab9cd4c8eadfbfe959f76dc8eae81fe5"
)


def split_values(raw: str) -> list[str]:
    return [part for part in re.split(r"[,\s]+", raw.strip()) if part]


def truthy(raw: str, default: bool = False) -> bool:
    text = str(raw or "").strip().lower()
    if not text:
        return default
    return text in {"1", "true", "yes", "y", "on", "always"}


def env_first(*names: str) -> str:
    for name in names:
        value = os.environ.get(name, "")
        if str(value).strip():
            return str(value)
    return ""


def numeric_values(raw: str) -> list[float]:
    out: list[float] = []
    for value in split_values(raw):
        try:
            out.append(float(value))
        except ValueError as exc:
            raise SystemExit(f"Expected numeric profile value, got {value!r}.") from exc
    return out


def format_number(value: float) -> str:
    if value.is_integer():
        return str(int(value))
    return f"{value:g}"


def split_profile_chains(values: list[float], center_raw: str) -> dict[str, list[float]]:
    if not values:
        return {}
    center = None
    if str(center_raw or "").strip():
        try:
            center = float(center_raw)
        except ValueError as exc:
            raise SystemExit(f"PROFILE_CENTER must be numeric, got {center_raw!r}.") from exc
    if center is None:
        center = min(values, key=lambda value: abs(value - 100.0))
    downstream = sorted([value for value in values if value <= center], reverse=True)
    upstream = sorted([value for value in values if value > center])
    out = {}
    if downstream:
        out["downstream"] = downstream
    if upstream and upstream != downstream:
        out["upstream"] = upstream
    return out


def check_unit_specs(check: str, parallel_units: bool) -> list[dict[str, Any]]:
    if not parallel_units:
        return [{"label": "", "env": {}, "metadata": {}}]

    check_key = check.replace("_", "-").lower()
    if check_key == "jitter":
        seeds = split_values(env_first("JITTER_SEEDS", "JITTER_SEED"))
        return [
            {
                "label": f"seed {seed}",
                "env": {"JITTER_SEEDS": seed, "JITTER_SEED": seed},
                "metadata": {"check_unit_type": "seed", "check_unit": seed},
            }
            for seed in seeds
        ] or [{"label": "", "env": {}, "metadata": {}}]

    if check_key == "retro":
        peels = split_values(env_first("RETRO_PEELS", "RETRO_PEEL"))
        return [
            {
                "label": f"peel {peel}",
                "env": {"RETRO_PEELS": peel, "RETRO_PEEL": peel},
                "metadata": {"check_unit_type": "peel", "check_unit": peel},
            }
            for peel in peels
        ] or [{"label": "", "env": {}, "metadata": {}}]

    if check_key == "selftest":
        reps = split_values(env_first("SELFTEST_REPS", "SELFTEST_REP"))
        return [
            {
                "label": f"rep {rep}",
                "env": {"SELFTEST_REPS": rep, "SELFTEST_REP": rep},
                "metadata": {"check_unit_type": "replicate", "check_unit": rep},
            }
            for rep in reps
        ] or [{"label": "", "env": {}, "metadata": {}}]

    if check_key == "profile":
        values = numeric_values(env_first("PROFILE_VALUES", "MFK_SCALAR"))
        profile_name = os.environ.get("PROFILE_NAME", "profile")
        label_name = profile_name if profile_name and profile_name != "profile" else "scalar"
        mode = os.environ.get("PROFILE_PARALLEL_MODE", "chains").strip().lower() or "chains"
        if mode in {"chain", "chains", "left-right", "left_right", "upstream-downstream", "upstream_downstream"}:
            chains = split_profile_chains(values, os.environ.get("PROFILE_CENTER", ""))
            return [
                {
                    "label": f"{side} chain",
                    "env": {
                        "PROFILE_VALUES": " ".join(format_number(value) for value in chain_values),
                        "PROFILE_CHAIN": "true",
                        "PROFILE_CHAIN_SIDE": side,
                    },
                    "metadata": {
                        "check_unit_type": "profile_chain",
                        "check_unit": side,
                        "profile_chain_values": " ".join(format_number(value) for value in chain_values),
                    },
                }
                for side, chain_values in chains.items()
            ] or [{"label": "", "env": {}, "metadata": {}}]
        if mode in {"scalar", "scalars", "point", "points"}:
            raise SystemExit(
                "PROFILE_PARALLEL_MODE=scalars is not supported for these checks. "
                "Use PROFILE_PARALLEL_MODE=chains so profile points run as left/right chains."
            )
        raise SystemExit(f"Unsupported PROFILE_PARALLEL_MODE={mode!r}. Use chains.")

    if check_key == "hessian":
        parts = split_values(env_first("HESSIAN_PARTS", "HESSIAN_PART"))
        nsplit = env_first("HESSIAN_NSPLIT", "NSPLIT") or "30"
        if not parts and nsplit:
            try:
                n = int(nsplit)
            except ValueError as exc:
                raise SystemExit(f"HESSIAN_NSPLIT must be an integer, got {nsplit!r}.") from exc
            if n < 1:
                raise SystemExit(f"HESSIAN_NSPLIT must be positive, got {nsplit!r}.")
            parts = [str(i) for i in range(1, n + 1)]
        return [
            {
                "label": f"part {part}/{nsplit or '?'}",
                "env": {"HESSIAN_PARTS": part, "HESSIAN_PART": part, **({"HESSIAN_NSPLIT": nsplit} if nsplit else {})},
                "metadata": {"check_unit_type": "hessian_part", "check_unit": part, **({"hessian_nsplit": nsplit} if nsplit else {})},
            }
            for part in parts
        ] or [{"label": "", "env": {}, "metadata": {}}]

    return [{"label": "", "env": {}, "metadata": {}}]


def merge_check_for(check: str) -> str:
    return MERGE_CHECKS.get(check.replace("_", "-").lower(), "")


def api_json(method: str, url: str, token: str, payload: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed: HTTP {exc.code}: {detail}") from exc
    return json.loads(raw.decode("utf-8")) if raw else {}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kflow-url", default=os.environ.get("KFLOW_URL", "http://127.0.0.1:8089"))
    parser.add_argument("--task-prefix", default="ofp-sam-bet-2026-check")
    parser.add_argument("--checks", default=os.environ.get("CHECK_TYPES", os.environ.get("CHECK_TYPE", "jitter")))
    parser.add_argument("--models", default=os.environ.get("MODEL_SELECTORS", os.environ.get("MODEL_SELECTOR", "")))
    parser.add_argument("--input-jobs", default=os.environ.get("KFLOW_INPUT_JOBS", ""))
    parser.add_argument("--flow-group", default=os.environ.get("FLOW_GROUP", "bet-2026-checks"))
    parser.add_argument("--model-source-repo", default=os.environ.get("MODEL_SOURCE_REPO", "PacificCommunity/ofp-sam-bet-2026-stepwise"))
    parser.add_argument("--model-source-ref", default=os.environ.get("MODEL_SOURCE_REF", "main"))
    parser.add_argument("--model-source-path", default=os.environ.get("MODEL_SOURCE_PATH", ""))
    parser.add_argument("--program-path", default=os.environ.get("PROGRAM_PATH", "/home/mfcl/mfclo64"))
    parser.add_argument("--submitter", default=os.environ.get("KFLOW_SUBMITTER", ""))
    parser.add_argument("--remote-host", default=os.environ.get("KFLOW_REMOTE_HOST", ""))
    parser.add_argument("--remote-user", default=os.environ.get("KFLOW_REMOTE_USER", ""))
    parser.add_argument("--remote-base-dir", default=os.environ.get("KFLOW_REMOTE_BASE_DIR", ""))
    parser.add_argument("--job-title", default=os.environ.get("JOB_TITLE", ""))
    parser.add_argument("--job-description", default=os.environ.get("JOB_DESCRIPTION", ""))
    parser.add_argument("--parallel-units", default=os.environ.get("KFLOW_PARALLEL_UNITS", "true"))
    parser.add_argument("--auto-merge", default=os.environ.get("KFLOW_AUTO_MERGE", "true"))
    parser.add_argument("--auto-attach", default=os.environ.get("KFLOW_AUTO_ATTACH", "true"))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = os.environ.get("KFLOW_API_TOKEN", "")
    if not token and not args.dry_run:
        raise SystemExit("Set KFLOW_API_TOKEN before submitting Kflow jobs.")

    checks = split_values(args.checks)
    models = split_values(args.models)
    if not checks:
        raise SystemExit("No checks selected.")
    if not models:
        raise SystemExit("No models selected. Set MODEL_SELECTOR or MODEL_SELECTORS.")
    input_jobs = [job.lstrip("#") for job in split_values(args.input_jobs)]
    base_url = args.kflow_url.rstrip("/")
    parallel_units = truthy(args.parallel_units, default=True)
    auto_merge = truthy(args.auto_merge, default=True)
    auto_attach = truthy(args.auto_attach, default=True)
    base_input_job = input_jobs[0] if input_jobs else ""
    submitter_fields = {
        "remote_host": args.submitter or args.remote_host,
        "remote_user": args.remote_user,
        "remote_base_dir": args.remote_base_dir,
    }
    submitter_fields = {key: value for key, value in submitter_fields.items() if str(value or "").strip()}

    submitted_groups: list[dict[str, Any]] = []

    for check in checks:
        for model in models:
            unit_job_ids: list[str] = []
            unit_specs = check_unit_specs(check, parallel_units)
            for unit in unit_specs:
                task = f"{args.task_prefix}-{check}"
                unit_label = str(unit.get("label") or "").strip()
                title = args.job_title or (
                    f"{check} {unit_label}: {model}" if unit_label else f"{check}: {model}"
                )
                description = args.job_description or (
                    f"Run {check} {unit_label} check for {model}."
                    if unit_label else
                    f"Run {check} check for {model}."
                )
                env = {
                    "CHECK_TYPE": check,
                    "MODEL_SELECTOR": model,
                    "KFLOW_JOB_TITLE": title,
                    "KFLOW_JOB_DESCRIPTION": description,
                    "MODEL_SOURCE_REPO": args.model_source_repo,
                    "MODEL_SOURCE_REF": args.model_source_ref,
                    "MODEL_SOURCE_PATH": args.model_source_path,
                    "PROGRAM_PATH": args.program_path,
                    "FLOW_GROUP": args.flow_group,
                    "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
                    "TUNA_FLOW_RUNTIME_UPDATE": os.environ.get("TUNA_FLOW_RUNTIME_UPDATE", "always"),
                    "KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS": os.environ.get("KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS", "0"),
                    "KFLOW_RUNTIME_PACKAGES": os.environ.get("KFLOW_RUNTIME_PACKAGES", DEFAULT_RUNTIME_PACKAGES),
                    "KFLOW_REPO_RUNTIME_PACKAGES": os.environ.get("KFLOW_REPO_RUNTIME_PACKAGES", "none"),
                    "KFLOW_REPO_RUNTIME_UPDATE": os.environ.get("KFLOW_REPO_RUNTIME_UPDATE", "always"),
                    "KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES": os.environ.get("KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES", "true"),
                    "KFLOW_RUNTIME_GITHUB_AUTH": os.environ.get("KFLOW_RUNTIME_GITHUB_AUTH", "true"),
                    "KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME": os.environ.get("KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME", "true"),
                }
                env_prefixes = (
                    "BET_", "JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "ASPM_",
                    "SELFTEST_", "MFK_", "CHECK_", "selftest_",
                )
                passthrough_env = {"TRIGGER_NEXT"}
                protected_env = {
                    "CHECK_TYPE",
                    "MODEL_SELECTOR",
                    "KFLOW_JOB_TITLE",
                    "KFLOW_JOB_DESCRIPTION",
                }
                for key, value in os.environ.items():
                    if key in protected_env:
                        continue
                    if key.startswith(env_prefixes) or key in passthrough_env or key == "program_path":
                        env[key] = value
                if check.replace("_", "-").lower() == "selftest":
                    env.setdefault(
                        "SELFTEST_RUN_REFIT",
                        os.environ.get("SELFTEST_RUN_REFIT", os.environ.get("CHECK_SELFTEST_RUN_REFIT", "true")),
                    )
                env.update(unit.get("env", {}))
                env = {key: value for key, value in env.items() if value not in (None, "")}
                unit_metadata = unit.get("metadata", {})
                check_unit = str(unit_metadata.get("check_unit") or "")
                tags = {
                    "stage": "checks",
                    "flow": args.flow_group,
                    "check_type": check,
                    "model": model,
                }
                if check_unit:
                    tags["check_unit"] = check_unit
                payload: dict[str, Any] = {
                    **submitter_fields,
                    "env": env,
                    "title": title,
                    "description": description,
                    "input_jobs": input_jobs,
                    "metadata": {
                        "flow_group": args.flow_group,
                        "job_title": title,
                        "job_description": description,
                        "check_type": check,
                        "model_selector": model,
                        "input_jobs": input_jobs,
                        "parallel_units": parallel_units,
                        **unit_metadata,
                    },
                    "tags": tags,
                }
                if args.dry_run:
                    print(json.dumps({"task": task, "payload": payload}, indent=2, sort_keys=True))
                    unit_job_ids.append(f"DRY-{check}-{model}-{check_unit or 'unit'}")
                    continue
                response = api_json("POST", f"{base_url}/api/job/{task}", token, payload)
                job = response.get("job", response)
                code = job.get("job_number") or job.get("number") or job.get("code") or job.get("id") or "?"
                if code and code != "?":
                    unit_job_ids.append(str(code))
                print(f"submitted {task} {model}: job {code}")
            submitted_groups.append(
                {
                    "check": check,
                    "model": model,
                    "unit_job_ids": unit_job_ids,
                    "final_job_ids": list(unit_job_ids),
                }
            )

    for group in submitted_groups:
        check = group["check"]
        merge_check = merge_check_for(check)
        unit_job_ids = group["unit_job_ids"]
        if not auto_merge or not parallel_units or not merge_check or len(unit_job_ids) <= 1:
            continue
        model = group["model"]
        task = f"{args.task_prefix}-{merge_check}"
        title = args.job_title or f"{merge_check}: {model}"
        description = args.job_description or f"Merge split {check} check outputs for {model}."
        env = {
            "CHECK_TYPE": merge_check,
            "CHECK_MERGE_TYPE": check,
            "MODEL_SELECTOR": model,
            "KFLOW_JOB_TITLE": title,
            "KFLOW_JOB_DESCRIPTION": description,
            "MODEL_SOURCE_REPO": args.model_source_repo,
            "MODEL_SOURCE_REF": args.model_source_ref,
            "MODEL_SOURCE_PATH": args.model_source_path,
            "PROGRAM_PATH": args.program_path,
            "FLOW_GROUP": args.flow_group,
            "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
            "TUNA_FLOW_RUNTIME_UPDATE": os.environ.get("TUNA_FLOW_RUNTIME_UPDATE", "always"),
            "KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS": os.environ.get("KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS", "0"),
            "KFLOW_RUNTIME_PACKAGES": os.environ.get("KFLOW_RUNTIME_PACKAGES", DEFAULT_RUNTIME_PACKAGES),
            "KFLOW_REPO_RUNTIME_PACKAGES": os.environ.get("KFLOW_REPO_RUNTIME_PACKAGES", "none"),
            "KFLOW_REPO_RUNTIME_UPDATE": os.environ.get("KFLOW_REPO_RUNTIME_UPDATE", "always"),
            "KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES": os.environ.get("KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES", "true"),
            "KFLOW_RUNTIME_GITHUB_AUTH": os.environ.get("KFLOW_RUNTIME_GITHUB_AUTH", "true"),
            "KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME": os.environ.get("KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME", "true"),
        }
        for key, value in os.environ.items():
            if key in {"CHECK_TYPE", "MODEL_SELECTOR", "KFLOW_JOB_TITLE", "KFLOW_JOB_DESCRIPTION"}:
                continue
            if key.startswith(("BET_", "JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "ASPM_", "SELFTEST_", "MFK_", "CHECK_", "selftest_")) or key in {"TRIGGER_NEXT"} or key == "program_path":
                env[key] = value
        if check == "hessian":
            env["CHECK_TYPE"] = "hessian_merge"
        payload = {
            **submitter_fields,
            "env": {key: value for key, value in env.items() if value not in (None, "")},
            "title": title,
            "description": description,
            "input_jobs": unit_job_ids,
            "metadata": {
                "flow_group": args.flow_group,
                "job_title": title,
                "job_description": description,
                "check_type": merge_check,
                "merged_check_type": check,
                "model_selector": model,
                "input_jobs": unit_job_ids,
                "parallel_units": parallel_units,
                "auto_merge": True,
                "allow_failed_input_jobs": True,
            },
            "tags": {
                "stage": "checks",
                "flow": args.flow_group,
                "check_type": merge_check,
                "model": model,
                "merge_for": check,
            },
        }
        if args.dry_run:
            print(json.dumps({"task": task, "payload": payload}, indent=2, sort_keys=True))
            group["final_job_ids"] = [f"DRY-{merge_check}-{model}-merge"]
            continue
        response = api_json("POST", f"{base_url}/api/job/{task}", token, payload)
        job = response.get("job", response)
        code = job.get("job_number") or job.get("number") or job.get("code") or job.get("id") or "?"
        if code and code != "?":
            group["final_job_ids"] = [str(code)]
        print(f"submitted {task} {model}: job {code}")

    if auto_attach and base_input_job:
        groups_by_model: dict[str, dict[str, Any]] = {}
        for group in submitted_groups:
            model = str(group["model"])
            item = groups_by_model.setdefault(model, {"checks": [], "job_ids": []})
            check = str(group["check"])
            if check not in item["checks"]:
                item["checks"].append(check)
            for job_id in group.get("final_job_ids") or []:
                if job_id and job_id not in item["job_ids"]:
                    item["job_ids"].append(str(job_id))

        for model, item in groups_by_model.items():
            final_job_ids = item["job_ids"]
            if not final_job_ids:
                continue
            checks_text = " ".join(item["checks"])
            task = f"{args.task_prefix}-attach-checks"
            title = f"diagnostics update: {model}"
            description = f"Attach completed model-check outputs to the base job for {model}."
            env = {
                "CHECK_TYPE": "attach-checks",
                "MODEL_SELECTOR": model,
                "MODEL_BASE_INPUT_JOB": base_input_job,
                "BASE_MODEL_JOB": base_input_job,
                "CHECK_INPUT_JOBS": " ".join(final_job_ids),
                "ATTACH_CHECK_TYPES": checks_text,
                "KFLOW_JOB_TITLE": title,
                "KFLOW_JOB_DESCRIPTION": description,
                "MODEL_SOURCE_REPO": args.model_source_repo,
                "MODEL_SOURCE_REF": args.model_source_ref,
                "MODEL_SOURCE_PATH": args.model_source_path,
                "PROGRAM_PATH": args.program_path,
                "FLOW_GROUP": args.flow_group,
                "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
                "TUNA_FLOW_RUNTIME_UPDATE": os.environ.get("TUNA_FLOW_RUNTIME_UPDATE", "always"),
                "KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS": os.environ.get("KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS", "0"),
                "KFLOW_RUNTIME_PACKAGES": os.environ.get("KFLOW_RUNTIME_PACKAGES", DEFAULT_RUNTIME_PACKAGES),
                "KFLOW_REPO_RUNTIME_PACKAGES": os.environ.get("KFLOW_REPO_RUNTIME_PACKAGES", "none"),
                "KFLOW_REPO_RUNTIME_UPDATE": os.environ.get("KFLOW_REPO_RUNTIME_UPDATE", "always"),
                "KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES": os.environ.get("KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES", "true"),
                "KFLOW_RUNTIME_GITHUB_AUTH": os.environ.get("KFLOW_RUNTIME_GITHUB_AUTH", "true"),
                "KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME": os.environ.get("KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME", "true"),
            }
            for key, value in os.environ.items():
                if key in {"CHECK_TYPE", "MODEL_SELECTOR", "KFLOW_JOB_TITLE", "KFLOW_JOB_DESCRIPTION"}:
                    continue
                if key.startswith(("BET_", "JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "ASPM_", "SELFTEST_", "MFK_", "CHECK_", "selftest_")) or key in {"TRIGGER_NEXT"} or key == "program_path":
                    env[key] = value
            payload = {
                **submitter_fields,
                "env": {key: value for key, value in env.items() if value not in (None, "")},
                "title": title,
                "description": description,
                "input_jobs": [base_input_job, *final_job_ids],
                "metadata": {
                    "flow_group": args.flow_group,
                    "job_title": title,
                    "job_description": description,
                    "check_type": "attach-checks",
                    "model_selector": model,
                    "base_job": base_input_job,
                    "input_jobs": [base_input_job, *final_job_ids],
                    "check_input_jobs": final_job_ids,
                    "attach_check_types": item["checks"],
                    "attached_work_parent_job": base_input_job,
                    "attached_work_latest": True,
                    "attached_work_group": f"{args.flow_group}:{model}:diagnostics",
                    "attached_work_label": f"{model} diagnostics",
                    "attached_work_summary": "Latest model-check outputs attached to the base job output bundle.",
                    "attached_work_role": "updated output",
                    "auto_attach": True,
                },
                "tags": {
                    "stage": "checks",
                    "flow": args.flow_group,
                    "check_type": "attach-checks",
                    "model": model,
                    "base_job": base_input_job,
                },
            }
            if args.dry_run:
                print(json.dumps({"task": task, "payload": payload}, indent=2, sort_keys=True))
                continue
            response = api_json("POST", f"{base_url}/api/job/{task}", token, payload)
            job = response.get("job", response)
            code = job.get("job_number") or job.get("number") or job.get("code") or job.get("id") or "?"
            print(f"submitted {task} {model}: job {code}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
