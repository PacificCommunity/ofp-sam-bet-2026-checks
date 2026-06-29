#!/usr/bin/env python3
"""Register or refresh one Kflow task from kflow.yaml."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]


def git(repo_root: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return ""
    return result.stdout.strip()


def repo_full_name(repo_root: Path) -> str:
    remote = git(repo_root, "remote", "get-url", "origin")
    if remote.endswith(".git"):
        remote = remote[:-4]
    if remote.startswith("git@github.com:"):
        return remote.split(":", 1)[1]
    marker = "github.com/"
    if marker in remote:
        return remote.split(marker, 1)[1].strip("/")
    return ""


def read_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a YAML mapping")
    return data


def api_json(method: str, url: str, token: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {token}"}
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed: HTTP {exc.code}: {detail}") from exc
    return json.loads(raw.decode("utf-8")) if raw else {}


def existing_report(base_url: str, token: str, task_name: str) -> dict[str, Any]:
    try:
        payload = api_json("GET", f"{base_url}/api/report/{task_name}", token)
    except Exception:
        return {}
    report = payload.get("report", payload)
    return report if isinstance(report, dict) else {}


def first_present(*values: Any) -> Any:
    for value in values:
        if value not in (None, ""):
            return value
    return None


def shared_local_apps() -> list[dict[str, Any]] | None:
    path = ROOT / "local_apps.yaml"
    if not path.exists():
        return None
    data = read_yaml(path)
    apps = data.get("local_apps")
    return apps if isinstance(apps, list) else None


def build_payload(config: dict[str, Any], repo_root: Path, existing: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    task_name = args.task_name or config.get("name")
    if not task_name:
        raise ValueError("Task name is missing.")
    resources = config.get("resources") or {}
    metadata = dict(config.get("metadata") or {})
    if config.get("job_config") is not None:
        metadata["job_config"] = config["job_config"]
    local_apps = config.get("local_apps", None)
    if local_apps is None:
        local_apps = shared_local_apps()
    if local_apps is not None:
        metadata["local_apps"] = local_apps

    payload: dict[str, Any] = {
        "name": task_name,
        "description": config.get("description", ""),
        "repo_full_name": first_present(args.repo_full_name, config.get("repo_full_name"), repo_full_name(repo_root)),
        "branch": first_present(args.branch, config.get("branch"), git(repo_root, "branch", "--show-current"), "main"),
        "command": config.get("command", existing.get("command")),
        "target_folder": config.get("target_folder", existing.get("target_folder", "")),
        "docker_image": config.get("docker_image", existing.get("docker_image")),
        "cpus": resources.get("cpus", existing.get("cpus")),
        "memory": resources.get("memory", existing.get("memory")),
        "disk": resources.get("disk", existing.get("disk")),
        "stream_error": config.get("stream_error", existing.get("stream_error", True)),
        "ghcr_login": config.get("ghcr_login", existing.get("ghcr_login", False)),
        "exclude_machines": config.get("exclude_machines", []),
        "exclude_slots": config.get("exclude_slots", []),
        "env": config.get("env", {}),
        "tags": config.get("tags", {}),
        "metadata": metadata,
        "output_patterns": config.get("output_patterns", []),
        "input_jobs": config.get("input_jobs", []),
        "triggers": config.get("triggers", {}),
    }
    return {key: value for key, value in payload.items() if value is not None}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="kflow.yaml")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--task-name", default="")
    parser.add_argument("--repo-full-name", default="")
    parser.add_argument("--branch", default="")
    parser.add_argument("--kflow-url", default=os.environ.get("KFLOW_URL", "http://127.0.0.1:8089"))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = (ROOT / args.repo_root).resolve()
    config_path = (ROOT / args.config).resolve()
    config = read_yaml(config_path)
    task_name = args.task_name or config.get("name")
    if not task_name:
        raise SystemExit("Task name is missing.")
    base_url = args.kflow_url.rstrip("/")
    token = os.environ.get("KFLOW_API_TOKEN", "")
    existing = existing_report(base_url, token, task_name) if token else {}
    payload = build_payload(config, repo_root, existing, args)
    if args.dry_run:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    if not token:
        raise SystemExit("Set KFLOW_API_TOKEN before registering Kflow tasks.")
    response = api_json("POST", f"{base_url}/api/report/{task_name}", token, payload)
    report = response.get("report", response)
    code = report.get("code", task_name) if isinstance(report, dict) else task_name
    print(f"registered {code}: {payload.get('repo_full_name', '')}@{payload.get('branch', '')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
