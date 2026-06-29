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


def split_values(raw: str) -> list[str]:
    return [part for part in re.split(r"[,\s]+", raw.strip()) if part]


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
    parser.add_argument("--job-title", default=os.environ.get("JOB_TITLE", ""))
    parser.add_argument("--job-description", default=os.environ.get("JOB_DESCRIPTION", ""))
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

    for check in checks:
        for model in models:
            task = f"{args.task_prefix}-{check}"
            title = args.job_title or f"{check}: {model}"
            description = args.job_description or f"Run {check} check for {model}."
            env = {
                "CHECK_TYPE": check,
                "MODEL_SELECTOR": model,
                "MODEL_SOURCE_REPO": args.model_source_repo,
                "MODEL_SOURCE_REF": args.model_source_ref,
                "MODEL_SOURCE_PATH": args.model_source_path,
                "PROGRAM_PATH": args.program_path,
                "FLOW_GROUP": args.flow_group,
                "KFLOW_REPO_RUNTIME_PACKAGES": os.environ.get("KFLOW_REPO_RUNTIME_PACKAGES", "mfclkit=PacificCommunity/ofp-sam-mfclkit@main"),
                "KFLOW_REPO_RUNTIME_UPDATE": os.environ.get("KFLOW_REPO_RUNTIME_UPDATE", "auto"),
                "KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES": os.environ.get("KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES", "true"),
                "KFLOW_RUNTIME_GITHUB_AUTH": os.environ.get("KFLOW_RUNTIME_GITHUB_AUTH", "true"),
                "KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME": os.environ.get("KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME", "true"),
            }
            for key, value in os.environ.items():
                if key.startswith(("JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "SELFTEST_", "MFK_")):
                    env[key] = value
            env = {key: value for key, value in env.items() if value not in (None, "")}
            payload: dict[str, Any] = {
                "env": env,
                "title": title,
                "description": description,
                "input_jobs": input_jobs,
                "metadata": {
                    "flow_group": args.flow_group,
                    "check_type": check,
                    "model_selector": model,
                    "input_jobs": input_jobs,
                },
                "tags": {
                    "stage": "checks",
                    "flow": args.flow_group,
                    "check_type": check,
                    "model": model,
                },
            }
            if args.dry_run:
                print(json.dumps({"task": task, "payload": payload}, indent=2, sort_keys=True))
                continue
            response = api_json("POST", f"{base_url}/api/job/{task}", token, payload)
            job = response.get("job", response)
            code = job.get("code") or job.get("id") or "?"
            print(f"submitted {task} {model}: job {code}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

