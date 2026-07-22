#!/usr/bin/env python3
"""Submit independent Kflow check jobs."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any


MERGE_CHECKS = {
    "aspm": "aspm-merge",
    "jitter": "jitter-merge",
    "retro": "retro-merge",
    "selftest": "selftest-merge",
    "profile": "profile-merge",
    "hessian": "hessian-merge",
}

CHECK_ALIASES = {
    "jiter": "jitter",
    "jitters": "jitter",
    "self": "selftest",
    "self-test": "selftest",
    "selftest": "selftest",
}

DEFAULT_RUNTIME_PACKAGES = (
    "mfclkit=PacificCommunity/ofp-sam-mfclkit@d8df08e2b7891cdb93b395aa84e0dcf770e3b09f,"
    "mfclshiny=PacificCommunity/mfclshiny@0b9e1a1b365ac8fd339ed4d59da73d573121ee1f"
)

DEFAULT_PROFILE_VALUES = [float(value) for value in range(60, 141, 2)]
DEFAULT_PROFILE_CENTER = "100"
DEFAULT_JITTER_SEEDS = [str(value) for value in range(1, 31)]
DEFAULT_RETRO_PEELS = [str(value) for value in range(1, 7)]
DEFAULT_SELFTEST_REPS = [str(value) for value in range(1, 31)]
DEFAULT_SELFTEST_REFIT_CONVERGENCE = "-3"
DEFAULT_CHECK_CPUS = "2"
DEFAULT_CHECK_MEMORY = "8GB"
DEFAULT_CHECK_DISK = "10GB"
DEFAULT_PROFILE_CPUS = "1"
DEFAULT_PROFILE_MEMORY = "8GB"
DEFAULT_PROFILE_MERGE_CPUS = "1"
DEFAULT_PROFILE_MERGE_MEMORY = "4GB"
DEFAULT_PROFILE_HBASE_MERGE_CPUS = "2"
DEFAULT_PROFILE_HBASE_MERGE_MEMORY = "16GB"
DEFAULT_PROFILE_REPAIR_CPUS = "2"
DEFAULT_PROFILE_REPAIR_MEMORY_GB = "16"
DEFAULT_PROFILE_REPAIR_MEMORY_PER_WORKER_GB = "8"
SUVA_HOST = "suvofpsubmit.corp.spc.int"
SUVA_USER = "kyuhank"
SUVA_BASE_DIR = "/home/kyuhank/KflowOutput"
SUVA_SLOT_REQUIREMENT = 'regexp("^suvofp", Machine)'
MAX_R_INTEGER = 2_147_483_647
HBASE_PROFILE_MODES = {"h-base", "h_base", "hbase", "hessian-base", "hessian_base"}
DIAGNOSTIC_OVERLAY_REPLACE_NAMES = [
    "jitter",
    "retro",
    "hessian",
    "profile",
    "selftest",
    "aspm",
    "projection",
]

_RUNTIME_GITHUB_TOKEN: str | None = None


def runtime_github_token() -> str:
    """Return a cached local GitHub token for one-request Kflow forwarding."""

    global _RUNTIME_GITHUB_TOKEN
    if _RUNTIME_GITHUB_TOKEN is not None:
        return _RUNTIME_GITHUB_TOKEN
    for name in ("KFLOW_GITHUB_TOKEN", "GITHUB_PAT", "GIT_PAT", "GH_TOKEN", "GITHUB_TOKEN"):
        value = str(os.environ.get(name) or "").strip()
        if value:
            _RUNTIME_GITHUB_TOKEN = value
            return value
    try:
        result = subprocess.run(
            ["gh", "auth", "token"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        value = result.stdout.strip()
        if result.returncode == 0 and re.fullmatch(r"(?:gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)", value):
            _RUNTIME_GITHUB_TOKEN = value
            return value
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    config_roots = [
        Path(os.environ.get("GH_CONFIG_DIR", "")),
        Path(os.environ.get("XDG_CONFIG_HOME", "")) / "gh",
        Path.home() / ".config" / "gh",
        Path(os.environ.get("APPDATA", "")) / "GitHub CLI",
        Path.home() / "Library" / "Application Support" / "gh",
    ]
    for root in config_roots:
        if not str(root).strip() or str(root) == ".":
            continue
        path = root / "hosts.yml"
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        match = re.search(r"^\s*oauth_token:\s*['\"]?([^'\"#\s]+)", text, re.MULTILINE)
        if match:
            _RUNTIME_GITHUB_TOKEN = match.group(1)
            return _RUNTIME_GITHUB_TOKEN
    _RUNTIME_GITHUB_TOKEN = ""
    return ""
DIRECT_MERGE_CHECKS = tuple(MERGE_CHECKS)
PARALLEL_SUBMISSION_CHECKS = {"jitter", "selftest", "retro", "hessian"}


def split_values(raw: str) -> list[str]:
    return [part for part in re.split(r"[,\s]+", raw.strip()) if part]


def flow_metadata_env() -> dict[str, str]:
    """Pass input-driven report metadata through every check workflow stage."""
    keys = ("FLOW_SPECIES", "FLOW_SPECIES_LABEL", "FLOW_ASSESSMENT_YEAR")
    return {
        key: str(os.environ.get(key, "")).strip()
        for key in keys
        if str(os.environ.get(key, "")).strip()
    }


def positive_integer_values(
    raw: str,
    *,
    default: list[str] | tuple[str, ...],
    option: str,
) -> list[str]:
    """Validate, canonicalize, and stably deduplicate R integer unit IDs."""
    text = str(raw or "")
    values = split_values(text) if text.strip() else [str(value) for value in default]
    if not values:
        raise SystemExit(f"{option} must contain at least one positive integer.")

    canonical: list[str] = []
    for value in values:
        if not re.fullmatch(r"[+]?[0-9]+", value):
            raise SystemExit(f"{option} must contain positive integers; got {value!r}.")
        parsed = int(value, 10)
        if parsed < 1 or parsed > MAX_R_INTEGER:
            raise SystemExit(
                f"{option} values must be between 1 and {MAX_R_INTEGER}; got {value!r}."
            )
        normalized = str(parsed)
        if normalized not in canonical:
            canonical.append(normalized)
    return canonical


def normalize_check_name(check: str) -> str:
    key = re.sub(r"[_\s]+", "-", str(check or "").strip().lower())
    return CHECK_ALIASES.get(key, key)


def truthy(raw: str, default: bool = False) -> bool:
    text = str(raw or "").strip().lower()
    if not text:
        return default
    return text in {"1", "true", "yes", "y", "on", "always"}


def resolve_submit_workers(raw: str) -> tuple[int, str]:
    """Resolve API submission concurrency from current local capacity."""
    text = str(raw or "auto").strip().lower()
    if text not in {"", "auto"}:
        try:
            workers = int(text)
        except ValueError as exc:
            raise SystemExit(
                "--submit-workers/KFLOW_SUBMIT_WORKERS must be auto or an integer."
            ) from exc
        if workers < 1 or workers > 32:
            raise SystemExit(
                "--submit-workers/KFLOW_SUBMIT_WORKERS must be between 1 and 32."
            )
        return workers, "explicit"

    try:
        cpu_count = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        cpu_count = os.cpu_count() or 1
    cpu_count = max(1, int(cpu_count))

    try:
        load_one = max(0.0, float(os.getloadavg()[0]))
    except (AttributeError, OSError):
        load_one = 0.0

    # Leave one logical CPU for the desktop and existing work. Submission is
    # network-bound, but this conservative cap prevents bursts when the local
    # machine is already busy.
    cpu_workers = max(1, int(cpu_count - load_one - 1.0))

    available_memory_mib = 0.0
    try:
        with open("/proc/meminfo", encoding="ascii") as handle:
            for line in handle:
                if line.startswith("MemAvailable:"):
                    available_memory_mib = float(line.split()[1]) / 1024.0
                    break
    except (OSError, ValueError, IndexError):
        pass
    memory_workers = (
        max(1, int(available_memory_mib // 256.0))
        if available_memory_mib > 0.0
        else 32
    )
    workers = max(1, min(32, cpu_workers, memory_workers))
    detail = (
        f"auto: cpus={cpu_count}, load1={load_one:.2f}, "
        f"available_memory={available_memory_mib / 1024.0:.1f}GiB"
        if available_memory_mib > 0.0
        else f"auto: cpus={cpu_count}, load1={load_one:.2f}"
    )
    return workers, detail


def env_first(*names: str) -> str:
    for name in names:
        value = os.environ.get(name, "")
        if str(value).strip():
            return str(value)
    return ""


def remote_base_dir_value(base_dir: str, remote_user: str, remote_host: str) -> str:
    text = str(base_dir or "").strip()
    if not text or text.startswith("/") or not str(remote_host or "").strip():
        return text
    user = str(remote_user or os.environ.get("USER") or "").strip() or "kyuhank"
    return f"/home/{user}/{text.strip('/')}"


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


def is_hbase_profile_mode(raw: str) -> bool:
    return str(raw or "").strip().lower().replace(" ", "-") in HBASE_PROFILE_MODES


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
    downstream = sorted([value for value in values if value < center], reverse=True)
    upstream = sorted([value for value in values if value > center])
    out = {}
    if downstream:
        out["downstream"] = downstream
    if upstream and upstream != downstream:
        out["upstream"] = upstream
    return out


def profile_values_from_env() -> list[float]:
    mode = profile_value_mode()
    raw = (
        env_first("MFK_PROFILE_TARGET_VALUES", "PROFILE_TARGET_VALUES")
        if mode == "absolute"
        else env_first("MFK_PROFILE_VALUES", "PROFILE_VALUES", "MFK_SCALAR")
    )
    if not raw:
        if mode == "absolute":
            raise SystemExit(
                "PROFILE_VALUE_MODE=absolute requires PROFILE_TARGET_VALUES."
            )
        return list(DEFAULT_PROFILE_VALUES)
    return numeric_values(raw)


def profile_value_mode() -> str:
    raw = env_first("MFK_PROFILE_VALUE_MODE", "PROFILE_VALUE_MODE")
    target_raw = env_first("MFK_PROFILE_TARGET_VALUES", "PROFILE_TARGET_VALUES")
    key = raw.strip().lower().replace("-", "_") if raw else (
        "absolute" if target_raw else "percent"
    )
    mode = {
        "percent": "percent",
        "percentage": "percent",
        "scalar": "percent",
        "scalars": "percent",
        "absolute": "absolute",
        "actual": "absolute",
        "target": "absolute",
        "targets": "absolute",
    }.get(key)
    if mode is None:
        raise SystemExit(
            f"Unsupported PROFILE_VALUE_MODE={raw!r}; use percent or absolute."
        )
    return mode


def resolved_profile_env(values: list[float] | None = None) -> dict[str, str]:
    """Resolve one profile contract for side jobs and their merge job."""
    values = list(profile_values_from_env() if values is None else values)
    value_mode = profile_value_mode()
    center_raw = (
        env_first("MFK_PROFILE_TARGET_CENTER", "PROFILE_TARGET_CENTER")
        if value_mode == "absolute"
        else env_first("MFK_PROFILE_CENTER", "PROFILE_CENTER")
    )
    if value_mode == "absolute" and not center_raw:
        raise SystemExit(
            "PROFILE_VALUE_MODE=absolute requires PROFILE_TARGET_CENTER set to "
            "the fitted model's actual quantity."
        )
    center_raw = center_raw or DEFAULT_PROFILE_CENTER
    try:
        center = float(center_raw)
    except ValueError as exc:
        raise SystemExit(f"PROFILE_CENTER must be numeric, got {center_raw!r}.") from exc

    profile_type = env_first("MFK_PROFILE_TYPE", "PROFILE_TYPE") or "quantity"
    profile_name = env_first(
        "MFK_PROFILE_NAME", "PROFILE_NAME", "MFK_PROFILE"
    ) or "total_average_biomass"
    profile_label = env_first("MFK_PROFILE_LABEL", "PROFILE_LABEL") or profile_name
    quantity = env_first("MFK_PROFILE_QUANTITY", "PROFILE_QUANTITY") or "avg_bio"
    quantity_type = env_first("MFK_PROFILE_QUANTITY_TYPE", "PROFILE_QUANTITY_TYPE") or "2"

    # Robust-fast is the default. Explicit PROFILE_PRESET or legacy
    # PROFILE_STYLE/PROFILE_RUNNER values continue to select another preset.
    legacy_style = env_first("PROFILE_STYLE", "PROFILE_RUNNER") or "robust_fast"
    preset = env_first("MFK_PROFILE_PRESET", "PROFILE_PRESET")
    if not preset:
        style_key = legacy_style.strip().lower().replace("-", "_")
        preset = {
            "bet": "adaptive",
            "ramp": "adaptive",
            "quantity_ramp": "adaptive",
            "adaptive": "adaptive",
            "robust_fast": "robust_fast",
            "three_stage": "three_stage",
            "manual": "manual_7stage",
            "manual_7stage": "manual_7stage",
            # The runner maps this compatibility value to a one-stage plan.
            "simple": "three_stage",
        }.get(style_key, style_key)
    preset_key = preset.strip().lower().replace("-", "_")
    preset = {
        "native_3stage": "three_stage",
        "standard_3stage": "three_stage",
        "3stage": "three_stage",
        "manual": "manual_7stage",
        "bet": "adaptive",
        "ramp": "adaptive",
        "quantity_ramp": "adaptive",
    }.get(preset_key, preset_key)
    if preset not in {"robust_fast", "three_stage", "manual_7stage", "adaptive"}:
        raise SystemExit(
            f"Unsupported profile preset {preset!r}; use robust_fast, three_stage, "
            "manual_7stage, or adaptive."
        )

    preset_defaults = {
        # Empty values defer both vectors to mfclkit's preset definition.
        "robust_fast": ("", ""),
        "three_stage": ("100000 1000000 10000000", "50 50 2000"),
        "manual_7stage": (
            "100000 1000000 10000000 10000000 10000000 10000000 10000000",
            "15 25 25 1000 100 500 1000",
        ),
        # Preserve the established BET Kflow adaptive schedule.
        "adaptive": ("50000 500000 5000000", "15 25 25 500 500 200"),
    }
    default_penalties, default_reps = preset_defaults[preset]

    jagged_repair_passes = env_first(
        "MFK_PROFILE_JAGGED_REPAIR_PASSES",
        "PROFILE_JAGGED_REPAIR_PASSES",
        "PROFILE_HBASE_REPAIR_PASSES",
    ) or "2"
    # Generic repair resources are the public contract. Mirror them to the old
    # h-base names below while existing registered h-base tasks still consume
    # those aliases.
    repair_cpus = env_first(
        "PROFILE_REPAIR_CPUS", "PROFILE_HBASE_REPAIR_CPUS",
    ) or DEFAULT_PROFILE_REPAIR_CPUS
    repair_memory_gb = env_first(
        "PROFILE_REPAIR_MEMORY_GB", "PROFILE_HBASE_REPAIR_MEMORY_GB",
    ) or DEFAULT_PROFILE_REPAIR_MEMORY_GB
    repair_memory_per_worker_gb = env_first(
        "PROFILE_REPAIR_MEMORY_PER_WORKER_GB",
        "PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB",
    ) or DEFAULT_PROFILE_REPAIR_MEMORY_PER_WORKER_GB

    include_anchor = truthy(
        env_first("MFK_PROFILE_INCLUDE_BASE_ANCHOR", "PROFILE_INCLUDE_BASE_ANCHOR"),
        default=True,
    )
    # Split profile chains deliberately omit the center.  When the fitted
    # model anchor is disabled, remove that value from both the submitted grid
    # and the expected merge contract; otherwise every such launch would
    # correctly, but unhelpfully, be marked incomplete for a point it cannot
    # produce.
    if not include_anchor:
        values = [value for value in values if abs(value - center) > 1e-10]
    expected_raw = env_first("MFK_PROFILE_EXPECTED_VALUES", "PROFILE_EXPECTED_VALUES")
    if expected_raw:
        expected = numeric_values(expected_raw)
    else:
        expected = list(values)
    if include_anchor and not any(abs(value - center) <= 1e-10 for value in expected):
        expected.append(center)
    if not include_anchor:
        expected = [value for value in expected if abs(value - center) > 1e-10]
    expected = sorted(set(expected))

    execution_mode_raw = env_first(
        "MFK_PROFILE_EXECUTION_MODE", "PROFILE_EXECUTION_MODE",
    ) or "continuation"
    execution_mode_key = execution_mode_raw.strip().lower().replace("-", "_")
    execution_mode = {
        "continuation": "continuation",
        "fitted_par": "continuation",
        "final_par": "continuation",
        "ramp": "continuation",
        "legacy": "continuation",
        "doitall": "doitall",
        "full_doitall": "doitall",
    }.get(execution_mode_key)
    if execution_mode is None:
        raise SystemExit(
            f"Unsupported PROFILE_EXECUTION_MODE={execution_mode_raw!r}. "
            "Use continuation or doitall."
        )

    resolved = {
        "PROFILE_SPEC_VERSION": "mfclkit.quantity-profile.v2",
        "PROFILE_TYPE": profile_type,
        "PROFILE_NAME": profile_name,
        "PROFILE_LABEL": profile_label,
        "PROFILE_QUANTITY": quantity,
        "PROFILE_QUANTITY_TYPE": quantity_type,
        "PROFILE_VALUE_MODE": value_mode,
        "PROFILE_VALUES": (
            " ".join(format_number(value) for value in values)
            if value_mode == "percent" else ""
        ),
        "PROFILE_TARGET_VALUES": (
            " ".join(format_number(value) for value in values)
            if value_mode == "absolute" else ""
        ),
        "PROFILE_TARGET_CENTER": (
            format_number(center) if value_mode == "absolute" else ""
        ),
        "PROFILE_EXPECTED_VALUES": " ".join(format_number(value) for value in expected),
        "PROFILE_CENTER": format_number(center),
        "PROFILE_PRESET": preset,
        "PROFILE_REPAIR_STRICTNESS": env_first(
            "MFK_PROFILE_REPAIR_STRICTNESS", "PROFILE_REPAIR_STRICTNESS",
            "PROFILE_REPAIR_STRICT",
        ) or "",
        "PROFILE_STYLE": legacy_style,
        "PROFILE_PARALLEL_MODE": (
            "h-base"
            if is_hbase_profile_mode(env_first("PROFILE_PARALLEL_MODE"))
            else env_first("PROFILE_PARALLEL_MODE") or "chains"
        ),
        "PROFILE_EXECUTION_MODE": execution_mode,
        "PROFILE_DOITALL_PENALTY": env_first(
            "MFK_PROFILE_DOITALL_PENALTY", "PROFILE_DOITALL_PENALTY",
        ) or "10000000",
        "PROFILE_DOITALL_SCRIPT": env_first(
            "MFK_PROFILE_DOITALL_SCRIPT", "PROFILE_DOITALL_SCRIPT",
        ) or "doitall.sh",
        "PROFILE_DOITALL_CONVERGENCE": env_first(
            "MFK_PROFILE_DOITALL_CONVERGENCE", "PROFILE_DOITALL_CONVERGENCE",
        ) or "-3",
        "PROFILE_CONVERGENCE_EXPONENT": env_first(
            "MFK_PROFILE_CONVERGENCE_EXPONENT", "PROFILE_CONVERGENCE_EXPONENT",
        ) or "-3",
        "PROFILE_POST_MERGE_REPAIR": env_first(
            "MFK_PROFILE_POST_MERGE_REPAIR", "PROFILE_POST_MERGE_REPAIR",
        ) or "false",
        "PROFILE_REVERSE_ONCE": env_first(
            "MFK_PROFILE_REVERSE_ONCE", "PROFILE_REVERSE_ONCE",
        ) or "true",
        "PROFILE_CHAIN": env_first("MFK_PROFILE_CHAIN", "PROFILE_CHAIN") or "true",
        "PROFILE_INCLUDE_BASE_ANCHOR": "true" if include_anchor else "false",
        "PROFILE_AF172": env_first("MFK_PROFILE_AF172", "PROFILE_AF172") or "0",
        "PROFILE_AF173": env_first("MFK_PROFILE_AF173", "PROFILE_AF173") or "0",
        "PROFILE_AF174": env_first("MFK_PROFILE_AF174", "PROFILE_AF174") or "0",
        "PROFILE_PENALTIES": env_first(
            "MFK_PROFILE_PENALTIES", "PROFILE_PENALTIES",
            "PROFILE_RAMP_PENALTIES", "PROFILE_PENALTY_SCHEDULE",
        ) or default_penalties,
        "PROFILE_RAMP_REPS": env_first(
            "MFK_PROFILE_RAMP_REPS", "PROFILE_RAMP_REPS", "PROFILE_REPS",
        ) or default_reps,
        "PROFILE_DISTANCE_BREAKS": env_first(
            "MFK_PROFILE_DISTANCE_BREAKS", "PROFILE_DISTANCE_BREAKS",
            "PROFILE_RAMP_DISTANCE_BREAKS",
        ) or "20 35",
        "PROFILE_PENALTY_SCALES": env_first(
            "MFK_PROFILE_PENALTY_SCALES", "PROFILE_PENALTY_SCALES",
            "PROFILE_RAMP_PENALTY_SCALES",
        ) or "1 2 4",
        "PROFILE_REPS_SCALES": env_first(
            "MFK_PROFILE_REPS_SCALES", "PROFILE_REPS_SCALES",
            "PROFILE_RAMP_REPS_SCALES",
        ) or "1 1.25 1.5",
        "PROFILE_EXTRA_FAR_REFINE": env_first(
            "MFK_PROFILE_EXTRA_FAR_REFINE", "PROFILE_EXTRA_FAR_REFINE",
            "PROFILE_RAMP_EXTRA_FAR_REFINE",
        ) or "true",
        "PROFILE_INCLUDE_FLAG55": env_first(
            "MFK_PROFILE_INCLUDE_FLAG55", "PROFILE_INCLUDE_FLAG55",
            "PROFILE_INCLUDE_LEGACY_FLAG55",
        ) or "true",
        "PROFILE_EXTRA_SWITCH": env_first("MFK_PROFILE_EXTRA_SWITCH", "PROFILE_EXTRA_SWITCH"),
        "PROFILE_BASE_QUANTITY": env_first("MFK_PROFILE_BASE_QUANTITY", "PROFILE_BASE_QUANTITY"),
        "PROFILE_MAX_GRAD_THRESHOLD": env_first(
            "MFK_PROFILE_MAX_GRAD_THRESHOLD", "PROFILE_MAX_GRAD_THRESHOLD",
        ),
        "PROFILE_TARGET_REL_TOLERANCE": env_first(
            "MFK_PROFILE_TARGET_REL_TOLERANCE", "PROFILE_TARGET_REL_TOLERANCE",
        ) or "0.001",
        "PROFILE_RETRY_INVALID": env_first(
            "MFK_PROFILE_RETRY_INVALID", "PROFILE_RETRY_INVALID",
        ) or "true",
        "PROFILE_RETRY_JAGGED": env_first(
            "MFK_PROFILE_RETRY_JAGGED", "PROFILE_RETRY_JAGGED",
        ) or "true",
        "PROFILE_CONTINUATION_REPS": env_first(
            "MFK_PROFILE_CONTINUATION_REPS", "PROFILE_CONTINUATION_REPS",
        ) or "1000",
        "PROFILE_INVALID_RETRY_PASSES": env_first(
            "MFK_PROFILE_INVALID_RETRY_PASSES", "PROFILE_INVALID_RETRY_PASSES",
        ) or "1",
        "PROFILE_JAGGED_REPAIR_PASSES": jagged_repair_passes,
        "PROFILE_MAX_JAGGED_REPAIRS": env_first(
            "MFK_PROFILE_MAX_JAGGED_REPAIRS", "PROFILE_MAX_JAGGED_REPAIRS",
        ) or "0",
        "PROFILE_JAGGED_TOLERANCE": env_first(
            "MFK_PROFILE_JAGGED_TOLERANCE", "PROFILE_JAGGED_TOLERANCE",
        ) or "0.1",
        "PROFILE_REPAIR_CPUS": repair_cpus,
        "PROFILE_REPAIR_MEMORY_GB": repair_memory_gb,
        "PROFILE_REPAIR_MEMORY_PER_WORKER_GB": repair_memory_per_worker_gb,
        "PROFILE_HBASE_ENABLED": (
            "true" if is_hbase_profile_mode(env_first("PROFILE_PARALLEL_MODE")) else "false"
        ),
        "PROFILE_HBASE_CONDITION_CAP": env_first("PROFILE_HBASE_CONDITION_CAP") or "10000000",
        "PROFILE_HBASE_EIGEN_FLOOR_RELATIVE": env_first("PROFILE_HBASE_EIGEN_FLOOR_RELATIVE") or "1e-10",
        "PROFILE_HBASE_NEGATIVE_TOLERANCE": env_first("PROFILE_HBASE_NEGATIVE_TOLERANCE") or "1e-8",
        "PROFILE_HBASE_MAX_QUADRATIC_STEP": env_first("PROFILE_HBASE_MAX_QUADRATIC_STEP") or "25",
        "PROFILE_HBASE_MAX_COORDINATE_STEP": env_first("PROFILE_HBASE_MAX_COORDINATE_STEP") or "0.35",
        "PROFILE_HBASE_BASE_REL_TOLERANCE": env_first("PROFILE_HBASE_BASE_REL_TOLERANCE") or "1e-5",
        "PROFILE_HBASE_RESTART_BASE": env_first("PROFILE_HBASE_RESTART_BASE") or "920000",
        "PROFILE_HBASE_REPAIR_PASSES": jagged_repair_passes,
        "PROFILE_HBASE_REPAIR_CPUS": repair_cpus,
        "PROFILE_HBASE_REPAIR_MEMORY_GB": repair_memory_gb,
        "PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB": repair_memory_per_worker_gb,
    }
    return {key: value for key, value in resolved.items() if str(value).strip()}


def resolved_profile_unit_env(values: list[float] | None = None) -> dict[str, str]:
    """Use cheap local recovery; assess profile shape only after both arms merge."""

    resolved = resolved_profile_env(values)
    if is_hbase_profile_mode(resolved.get("PROFILE_PARALLEL_MODE")):
        return resolved
    resolved.update({
        "PROFILE_RETRY_INVALID": env_first(
            "MFK_PROFILE_UNIT_RETRY_INVALID", "PROFILE_UNIT_RETRY_INVALID",
        ) or "true",
        "PROFILE_INVALID_RETRY_PASSES": env_first(
            "MFK_PROFILE_UNIT_INVALID_RETRY_PASSES",
            "PROFILE_UNIT_INVALID_RETRY_PASSES",
        ) or "1",
        "PROFILE_RETRY_JAGGED": env_first(
            "MFK_PROFILE_UNIT_RETRY_JAGGED", "PROFILE_UNIT_RETRY_JAGGED",
        ) or "false",
        "PROFILE_REVERSE_ONCE": env_first(
            "MFK_PROFILE_UNIT_REVERSE_ONCE", "PROFILE_UNIT_REVERSE_ONCE",
        ) or "true",
        "PROFILE_JAGGED_REPAIR_PASSES": env_first(
            "MFK_PROFILE_UNIT_JAGGED_REPAIR_PASSES",
            "PROFILE_UNIT_JAGGED_REPAIR_PASSES",
        ) or "0",
        "PROFILE_MAX_JAGGED_REPAIRS": env_first(
            "MFK_PROFILE_UNIT_MAX_JAGGED_REPAIRS",
            "PROFILE_UNIT_MAX_JAGGED_REPAIRS",
        ) or "0",
    })
    return resolved


def check_unit_specs(check: str, parallel_units: bool) -> list[dict[str, Any]]:
    check_key = normalize_check_name(check)
    if check_key == "aspm":
        return [{
            "label": "",
            "env": {},
            "metadata": {"check_unit_type": "aspm", "check_unit": "aspm"},
        }]

    integer_units = {
        "jitter": (
            "seed",
            "JITTER_SEEDS",
            "JITTER_SEED",
            DEFAULT_JITTER_SEEDS,
            "seed",
        ),
        "retro": (
            "peel",
            "RETRO_PEELS",
            "RETRO_PEEL",
            DEFAULT_RETRO_PEELS,
            "peel",
        ),
        "selftest": (
            "replicate",
            "SELFTEST_REPS",
            "SELFTEST_REP",
            DEFAULT_SELFTEST_REPS,
            "rep",
        ),
    }.get(check_key)
    if integer_units is not None:
        unit_type, plural_env, singular_env, defaults, label = integer_units
        raw = env_first(plural_env, singular_env)
        values = positive_integer_values(
            raw,
            default=defaults,
            option=f"{plural_env}/{singular_env}",
        )
        if not parallel_units:
            return [{
                "label": "",
                "env": {plural_env: " ".join(values), singular_env: ""},
                "metadata": {"check_unit_type": unit_type, "check_units": values},
            }]
        return [
            {
                "label": f"{label} {value}",
                "env": {plural_env: value, singular_env: value},
                "metadata": {"check_unit_type": unit_type, "check_unit": value},
            }
            for value in values
        ]

    if not parallel_units:
        if check_key == "profile":
            values = profile_values_from_env()
            common_env = resolved_profile_unit_env(values)
            mode = common_env["PROFILE_PARALLEL_MODE"].strip().lower() or "chains"
            execution_mode = common_env["PROFILE_EXECUTION_MODE"].strip().lower()
            if (
                mode in {
                    "chain", "chains", "left-right", "left_right",
                    "upstream-downstream", "upstream_downstream",
                }
                and execution_mode == "doitall"
            ):
                raise SystemExit(
                    "PROFILE_EXECUTION_MODE=doitall requires independent profile points. "
                    "Set PROFILE_PARALLEL_MODE=scalars, or keep chain mode with "
                    "PROFILE_EXECUTION_MODE=continuation."
                )
            return [{
                "label": "",
                "env": common_env,
                "metadata": {
                    "profile_name": common_env["PROFILE_NAME"],
                    "profile_preset": common_env["PROFILE_PRESET"],
                    "profile_repair_strictness": common_env.get("PROFILE_REPAIR_STRICTNESS", ""),
                    "profile_expected_values": common_env["PROFILE_EXPECTED_VALUES"],
                },
            }]
        return [{"label": "", "env": {}, "metadata": {}}]

    if check_key == "profile":
        values = profile_values_from_env()
        common_env = resolved_profile_unit_env(values)
        profile_name = common_env["PROFILE_NAME"]
        label_name = profile_name if profile_name and profile_name != "profile" else "scalar"
        mode = common_env["PROFILE_PARALLEL_MODE"].strip().lower() or "chains"
        execution_mode = common_env["PROFILE_EXECUTION_MODE"].strip().lower().replace("-", "_")
        if mode in {"chain", "chains", "left-right", "left_right", "upstream-downstream", "upstream_downstream"}:
            if execution_mode in {"doitall", "full_doitall"}:
                raise SystemExit(
                    "PROFILE_EXECUTION_MODE=doitall requires independent profile points. "
                    "Set PROFILE_PARALLEL_MODE=scalars, or keep chain mode with "
                    "PROFILE_EXECUTION_MODE=continuation."
                )
            center = common_env["PROFILE_CENTER"]
            chains = split_profile_chains(values, center)
            values_key = (
                "PROFILE_TARGET_VALUES"
                if common_env["PROFILE_VALUE_MODE"] == "absolute"
                else "PROFILE_VALUES"
            )
            return [
                {
                    "label": f"{side} chain",
                    "env": {
                        **common_env,
                        values_key: " ".join(format_number(value) for value in chain_values),
                        "PROFILE_CHAIN": "true",
                        "PROFILE_CHAIN_SIDE": side,
                        "PROFILE_CENTER": center,
                        "PROFILE_INCLUDE_BASE_ANCHOR": "false",
                    },
                    "metadata": {
                        "check_unit_type": "profile_chain",
                        "check_unit": side,
                        "profile_center": center,
                        "profile_name": profile_name,
                        "profile_preset": common_env["PROFILE_PRESET"],
                        "profile_repair_strictness": common_env.get("PROFILE_REPAIR_STRICTNESS", ""),
                        "profile_execution_mode": common_env["PROFILE_EXECUTION_MODE"],
                        "profile_doitall_penalty": common_env["PROFILE_DOITALL_PENALTY"],
                        "profile_doitall_script": common_env["PROFILE_DOITALL_SCRIPT"],
                        "profile_expected_values": common_env["PROFILE_EXPECTED_VALUES"],
                        "profile_chain_values": " ".join(format_number(value) for value in chain_values),
                    },
                }
                for side, chain_values in chains.items()
            ]
        if mode in {"scalar", "scalars", "point", "points", *HBASE_PROFILE_MODES}:
            if is_hbase_profile_mode(mode) and execution_mode not in {"continuation", "ramp", "legacy"}:
                raise SystemExit(
                    "PROFILE_PARALLEL_MODE=h-base requires PROFILE_EXECUTION_MODE=continuation."
                )
            center = float(common_env["PROFILE_CENTER"])
            values_key = (
                "PROFILE_TARGET_VALUES"
                if common_env["PROFILE_VALUE_MODE"] == "absolute"
                else "PROFILE_VALUES"
            )
            scalar_values = sorted({
                value for value in values if abs(value - center) > 1e-10
            })
            if not scalar_values:
                raise SystemExit(
                    "PROFILE_PARALLEL_MODE=scalars requires at least one non-center "
                    "PROFILE_VALUES entry."
                )
            specs = []
            for value in scalar_values:
                scalar = format_number(value)
                side = "downstream" if value < center else "upstream"
                specs.append({
                    "label": f"{label_name} {scalar}",
                    "env": {
                        **common_env,
                        values_key: scalar,
                        "PROFILE_CHAIN": "false",
                        "PROFILE_CHAIN_SIDE": side,
                        "PROFILE_CENTER": common_env["PROFILE_CENTER"],
                        "PROFILE_INCLUDE_BASE_ANCHOR": "false",
                        **({
                            "PROFILE_HBASE_ENABLED": "true",
                            "PROFILE_HBASE_ROLE": "scalar",
                        } if is_hbase_profile_mode(mode) else {}),
                    },
                    "metadata": {
                        "check_unit_type": "profile_scalar",
                        "check_unit": scalar,
                        "profile_scalar": scalar,
                        "profile_side": side,
                        "profile_center": common_env["PROFILE_CENTER"],
                        "profile_name": profile_name,
                        "profile_preset": common_env["PROFILE_PRESET"],
                        "profile_repair_strictness": common_env.get("PROFILE_REPAIR_STRICTNESS", ""),
                        "profile_execution_mode": common_env["PROFILE_EXECUTION_MODE"],
                        "profile_doitall_penalty": common_env["PROFILE_DOITALL_PENALTY"],
                        "profile_doitall_script": common_env["PROFILE_DOITALL_SCRIPT"],
                        "profile_expected_values": common_env["PROFILE_EXPECTED_VALUES"],
                    },
                })
            return specs
        raise SystemExit(
            f"Unsupported PROFILE_PARALLEL_MODE={mode!r}. Use scalars, chains, or h-base."
        )

    if check_key == "hessian":
        parts = split_values(env_first("HESSIAN_PARTS", "HESSIAN_PART"))
        nsplit = env_first("HESSIAN_NSPLIT", "NSPLIT") or "5"
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


def expected_unit_ledger(unit_specs: list[dict[str, Any]]) -> tuple[str, list[str]]:
    """Return the merge-side unit ledger encoded by split unit metadata."""
    supported_types = {"seed", "peel", "replicate", "aspm"}
    unit_type = ""
    units: list[str] = []
    for spec in unit_specs:
        metadata = spec.get("metadata") if isinstance(spec.get("metadata"), dict) else {}
        one_type = str(metadata.get("check_unit_type") or "").strip().lower()
        if one_type not in supported_types:
            continue
        if unit_type and one_type != unit_type:
            raise SystemExit(
                f"Split check unit specs mix incompatible unit types: {unit_type!r} and {one_type!r}."
            )
        unit_type = one_type
        many = metadata.get("check_units")
        if isinstance(many, (list, tuple)):
            candidates = [str(value).strip() for value in many if str(value).strip()]
        elif many is not None and str(many).strip():
            candidates = split_values(str(many))
        else:
            one_unit = str(metadata.get("check_unit") or "").strip()
            candidates = [one_unit] if one_unit else []
        units.extend(candidates)
    if unit_type in {"seed", "peel", "replicate"}:
        units = positive_integer_values(
            " ".join(units),
            default=(),
            option=f"expected {unit_type} units",
        )
    else:
        units = list(dict.fromkeys(units))
    return unit_type, units


def merge_check_for(check: str) -> str:
    return MERGE_CHECKS.get(normalize_check_name(check), "")


def api_timeout_seconds() -> float:
    raw = str(os.environ.get("KFLOW_API_TIMEOUT_SECONDS", "300")).strip()
    try:
        value = float(raw)
    except ValueError as exc:
        raise SystemExit("KFLOW_API_TIMEOUT_SECONDS must be numeric.") from exc
    if value <= 0:
        raise SystemExit("KFLOW_API_TIMEOUT_SECONDS must be greater than zero.")
    return value


def api_json(
    method: str,
    url: str,
    token: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Authorization": f"Bearer {token}"}
    github_token = runtime_github_token()
    if github_token:
        headers["X-GitHub-Token"] = github_token
    if payload is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        url,
        data=body,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=api_timeout_seconds()) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed: HTTP {exc.code}: {detail}") from exc
    return json.loads(raw.decode("utf-8")) if raw else {}


def check_task_resources(
    check_type: str,
    submitter_fields: dict[str, Any],
) -> dict[str, Any]:
    key = str(check_type or "").strip().lower().replace("_", "-")
    resources = {
        "cpus": int(submitter_fields.get("cpus") or DEFAULT_CHECK_CPUS),
        "memory": submitter_fields.get("memory") or DEFAULT_CHECK_MEMORY,
        "disk": submitter_fields.get("disk") or DEFAULT_CHECK_DISK,
    }
    if key == "profile":
        resources["cpus"] = int(
            os.environ.get("KFLOW_PROFILE_CPUS", DEFAULT_PROFILE_CPUS)
        )
        resources["memory"] = os.environ.get(
            "KFLOW_PROFILE_MEMORY", DEFAULT_PROFILE_MEMORY
        )
    elif key == "profile-merge":
        resources["cpus"] = int(os.environ.get(
            "KFLOW_PROFILE_MERGE_CPUS",
            DEFAULT_PROFILE_MERGE_CPUS,
        ))
        resources["memory"] = os.environ.get(
            "KFLOW_PROFILE_MERGE_MEMORY", DEFAULT_PROFILE_MERGE_MEMORY
        )
    elif key == "profile-h-base-merge":
        resources["cpus"] = int(os.environ.get(
            "KFLOW_PROFILE_HBASE_MERGE_CPUS", DEFAULT_PROFILE_HBASE_MERGE_CPUS
        ))
        resources["memory"] = os.environ.get(
            "KFLOW_PROFILE_HBASE_MERGE_MEMORY", DEFAULT_PROFILE_HBASE_MERGE_MEMORY
        )
    return resources


def ensure_check_task_registered(
    base_url: str,
    token: str,
    task: str,
    check_type: str,
    submitter_fields: dict[str, Any],
    registered_tasks: set[str],
) -> None:
    """Upsert an internal check task before creating jobs beneath it.

    Diagnostic task records are shared across submissions. Always refreshing
    the record prevents a previously registered, later-deleted temporary Git
    branch from poisoning every unit in a new diagnostic fan-out.
    """

    if task in registered_tasks:
        return
    endpoint = f"{base_url}/api/report/{task}"
    repo = str(submitter_fields.get("repo") or "").strip()
    if not repo:
        raise RuntimeError(f"Cannot register {task}: repository is missing.")
    resources = check_task_resources(check_type, submitter_fields)
    payload = {
        "name": task,
        "description": (
            f"Internal {check_type.replace('-', ' ')} jobs shown under their parent model."
        ),
        "repo_full_name": repo,
        "branch": submitter_fields.get("branch") or "main",
        "make_target": submitter_fields.get("make_target") or "all",
        "command": "bash run.sh",
        "checkout": {"mode": "full", "paths": []},
        "remote_user": submitter_fields.get("remote_user"),
        "remote_host": submitter_fields.get("remote_host"),
        "remote_base_dir": submitter_fields.get("remote_base_dir"),
        "slot_requirements": submitter_fields.get("slot_requirements"),
        "docker_image": submitter_fields.get("docker_image"),
        "cpus": resources["cpus"],
        "memory": resources["memory"],
        "disk": resources["disk"],
        "metadata": {
            "internal_task": True,
            "task_visibility": "internal",
            "task_role": "diagnostic-support",
            "check_type": check_type,
        },
        "tags": {"stage": "checks", "check_type": check_type},
        "output_patterns": ["outputs/**"],
    }
    api_json("POST", endpoint, token, payload)
    registered_tasks.add(task)


def api_get_json(url: str, token: str) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {token}"}
    github_token = runtime_github_token()
    if github_token:
        headers["X-GitHub-Token"] = github_token
    request = urllib.request.Request(
        url,
        headers=headers,
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=api_timeout_seconds()) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GET {url} failed: HTTP {exc.code}: {detail}") from exc
    return json.loads(raw.decode("utf-8")) if raw else {}


def api_job(base_url: str, token: str, ref: str) -> dict[str, Any]:
    if not str(ref or "").strip():
        return {}
    try:
        response = api_get_json(f"{base_url}/api/job/{str(ref).lstrip('#')}", token)
    except Exception:
        return {}
    job = response.get("job", response)
    return job if isinstance(job, dict) else {}


def latest_attached_output_job(base_url: str, token: str, base_job: str) -> str:
    if not str(base_job or "").strip():
        return ""
    job = api_job(base_url, token, base_job)
    metadata = job.get("metadata") if isinstance(job.get("metadata"), dict) else {}
    latest = metadata.get("attached_work_latest")
    if not isinstance(latest, dict):
        return ""
    output_job = str(latest.get("output_job") or "").strip().lstrip("#")
    if not output_job or output_job == str(base_job).strip().lstrip("#"):
        return ""
    # The parent pointer is authoritative, but validate the child before using
    # it as a prior standalone attachment. This rejects stale, failed, or
    # unrelated attached-work records.
    output = api_job(base_url, token, output_job)
    if not output:
        return ""
    output_metadata = output.get("metadata") if isinstance(output.get("metadata"), dict) else {}
    declared_parent = str(output_metadata.get("attached_work_parent_job") or "").strip().lstrip("#")
    if declared_parent != str(base_job).strip().lstrip("#"):
        return ""
    status = str(output.get("status") or "").strip().lower()
    if status not in {"success", "completed"}:
        return ""
    return output_job


def attached_output_ref(value: Any) -> str:
    if isinstance(value, dict):
        value = value.get("output_job") or value.get("job") or value.get("job_number") or ""
    return str(value or "").strip().lstrip("#")


def attached_work_slot_key(value: Any) -> str:
    text = str(value or "").strip().lower()
    return re.sub(r"[^a-z0-9_.-]+", "-", text).strip("-_.")


def latest_attached_output_jobs_by_slot(
    base_url: str,
    token: str,
    base_job: str,
) -> dict[str, str]:
    """Return safe completed same-slot predecessors for independent overlays."""
    parent = api_job(base_url, token, base_job)
    metadata = parent.get("metadata") if isinstance(parent.get("metadata"), dict) else {}
    raw = metadata.get("attached_work_latest_by_slot")
    if not isinstance(raw, dict):
        return {}
    out: dict[str, str] = {}
    normalized_base = str(base_job or "").strip().lstrip("#")
    for slot, value in raw.items():
        slot_key = attached_work_slot_key(slot)
        ref = attached_output_ref(value)
        if not slot_key or not ref or ref == normalized_base:
            continue
        child = api_job(base_url, token, ref)
        child_metadata = child.get("metadata") if isinstance(child.get("metadata"), dict) else {}
        child_parent = str(child_metadata.get("attached_work_parent_job") or "").strip().lstrip("#")
        child_slot = attached_work_slot_key(child_metadata.get("attached_work_slot"))
        status = str(child.get("status") or "").strip().lower()
        if child_parent != normalized_base or child_slot != slot_key or status not in {"success", "completed"}:
            continue
        out[slot_key] = ref
    return out


def diagnostic_attached_work_slot(model: str, check: str) -> str:
    return f"diagnostics:{model}:{check}"


def job_check_kind(job: dict[str, Any]) -> str:
    metadata = job.get("metadata") if isinstance(job.get("metadata"), dict) else {}
    tags = job.get("tags") if isinstance(job.get("tags"), dict) else {}
    values = [
        metadata.get("merged_check_type"),
        tags.get("merge_for"),
        metadata.get("check_type"),
        tags.get("check_type"),
    ]
    for value in values:
        text = normalize_check_name(str(value or ""))
        if text:
            return text.removesuffix("-merge")
    return ""


def metadata_refs(value: Any) -> list[str]:
    if isinstance(value, (list, tuple, set)):
        return split_values(" ".join(str(item) for item in value if str(item).strip()))
    return split_values(str(value or ""))


def job_model_selectors(job: dict[str, Any]) -> list[str]:
    """Return canonical model selectors advertised by one input job."""
    metadata = job.get("metadata") if isinstance(job.get("metadata"), dict) else {}
    tags = job.get("tags") if isinstance(job.get("tags"), dict) else {}
    values = [
        job.get("model_selector"),
        metadata.get("model_selector"),
        metadata.get("model_selectors"),
        metadata.get("model_key"),
        metadata.get("model_keys"),
        tags.get("model"),
    ]
    selectors: list[str] = []
    for value in values:
        for selector in metadata_refs(value):
            if selector and selector not in selectors:
                selectors.append(selector)
    return selectors


def resolve_input_models(
    base_url: str,
    token: str,
    base_input_job: str,
    requested: list[str],
) -> list[str]:
    """Resolve requested aliases against canonical selectors on the base job."""
    if not base_input_job or not token:
        return requested
    canonical = job_model_selectors(api_job(base_url, token, base_input_job))
    if not canonical:
        return requested
    if not requested:
        return canonical

    by_key = {value.casefold(): value for value in canonical}
    if len(canonical) == 1:
        if len(requested) != 1:
            raise SystemExit(
                f"Input job {base_input_job} contains one model ({canonical[0]}); "
                f"got {len(requested)} requested selectors."
            )
        if requested[0].casefold() != canonical[0].casefold():
            print(
                f"Resolved model selector {requested[0]!r} to {canonical[0]!r} "
                f"from input job {base_input_job}.",
                file=sys.stderr,
            )
        return [canonical[0]]

    unknown = [value for value in requested if value.casefold() not in by_key]
    if unknown:
        raise SystemExit(
            f"Requested model selectors are not present in input job {base_input_job}: "
            f"{', '.join(unknown)}. Available: {', '.join(canonical)}."
        )
    return [by_key[value.casefold()] for value in requested]


def previous_check_merge_jobs(base_url: str, token: str, attached_job_ref: str, check: str) -> list[str]:
    attached = api_job(base_url, token, attached_job_ref)
    metadata = attached.get("metadata") if isinstance(attached.get("metadata"), dict) else {}
    refs = metadata_refs(metadata.get("check_input_jobs"))
    if not refs:
        refs = metadata_refs(metadata.get("input_jobs"))
    out: list[str] = []
    for ref in refs:
        linked = api_job(base_url, token, ref)
        if job_check_kind(linked) == normalize_check_name(check):
            code = str(linked.get("job_number") or linked.get("number") or ref).strip().lstrip("#")
            if code and code not in out:
                out.append(code)
    return out


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kflow-url", default=os.environ.get("KFLOW_URL", "http://127.0.0.1:8089"))
    parser.add_argument("--task-prefix", default="ofp-sam-bet-2026-check")
    parser.add_argument("--checks", default=os.environ.get("CHECK_TYPES", os.environ.get("CHECK_TYPE", "jitter")))
    parser.add_argument("--models", default=os.environ.get("MODEL_SELECTORS", os.environ.get("MODEL_SELECTOR", "")))
    parser.add_argument("--input-jobs", default=os.environ.get("KFLOW_INPUT_JOBS", ""))
    parser.add_argument("--flow-group", default=os.environ.get("FLOW_GROUP", "bet-2026-checks"))
    parser.add_argument(
        "--repo-full-name",
        default=os.environ.get(
            "KFLOW_REPO_FULL_NAME",
            "PacificCommunity/ofp-sam-bet-2026-checks",
        ),
    )
    parser.add_argument("--branch", default=os.environ.get("KFLOW_BRANCH", "main"))
    parser.add_argument("--make-target", default=os.environ.get("KFLOW_MAKE_TARGET", "all"))
    parser.add_argument(
        "--docker-image",
        default=os.environ.get(
            "KFLOW_DOCKER_IMAGE",
            "ghcr.io/pacificcommunity/tuna-flow:v2.5@sha256:c87f1f6d9d4f62dc447844b58afe35f96af175bf933cb6cffbbbe39a59172360",
        ),
    )
    parser.add_argument("--cpus", default=os.environ.get("KFLOW_CPUS", DEFAULT_CHECK_CPUS))
    parser.add_argument("--memory", default=os.environ.get("KFLOW_MEMORY", DEFAULT_CHECK_MEMORY))
    parser.add_argument("--disk", default=os.environ.get("KFLOW_DISK", DEFAULT_CHECK_DISK))
    parser.add_argument("--model-source-repo", default=os.environ.get("MODEL_SOURCE_REPO", "PacificCommunity/ofp-sam-bet-2026-stepwise"))
    parser.add_argument("--model-source-ref", default=os.environ.get("MODEL_SOURCE_REF", "main"))
    parser.add_argument("--model-source-path", default=os.environ.get("MODEL_SOURCE_PATH", ""))
    parser.add_argument("--program-path", default=os.environ.get("PROGRAM_PATH", "/home/mfcl/mfclo64"))
    parser.add_argument("--submitter", default=os.environ.get("KFLOW_SUBMITTER", ""))
    parser.add_argument("--remote-host", default=os.environ.get("KFLOW_REMOTE_HOST", SUVA_HOST))
    parser.add_argument("--remote-user", default=os.environ.get("KFLOW_REMOTE_USER", SUVA_USER))
    parser.add_argument("--remote-base-dir", default=os.environ.get("KFLOW_REMOTE_BASE_DIR", SUVA_BASE_DIR))
    parser.add_argument("--slot-requirements", default=os.environ.get("KFLOW_SLOT_REQUIREMENTS", SUVA_SLOT_REQUIREMENT))
    parser.add_argument("--job-title", default=os.environ.get("JOB_TITLE", ""))
    parser.add_argument("--job-description", default=os.environ.get("JOB_DESCRIPTION", ""))
    parser.add_argument("--parallel-units", default=os.environ.get("KFLOW_PARALLEL_UNITS", "true"))
    parser.add_argument("--auto-merge", default=os.environ.get("KFLOW_AUTO_MERGE", "true"))
    parser.add_argument("--auto-attach", default=os.environ.get("KFLOW_AUTO_ATTACH", "true"))
    parser.add_argument("--submit-workers", default=os.environ.get("KFLOW_SUBMIT_WORKERS", "auto"))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = os.environ.get("KFLOW_API_TOKEN", "")
    if not token and not args.dry_run:
        raise SystemExit("Set KFLOW_API_TOKEN before submitting Kflow jobs.")
    if not args.dry_run and not runtime_github_token():
        raise SystemExit(
            "GitHub authentication is required for private runtime packages. "
            "Run `gh auth login` or set KFLOW_GITHUB_TOKEN/GITHUB_PAT."
        )

    checks = []
    for raw_check in split_values(args.checks):
        check = normalize_check_name(raw_check)
        if check and check not in checks:
            checks.append(check)
    requested_models = split_values(args.models)
    if not checks:
        raise SystemExit("No checks selected.")
    input_jobs = [job.lstrip("#") for job in split_values(args.input_jobs)]
    base_url = args.kflow_url.rstrip("/")
    base_input_job = input_jobs[0] if input_jobs else ""
    models = resolve_input_models(
        base_url,
        token,
        base_input_job,
        requested_models,
    )
    if not models:
        raise SystemExit(
            "No models selected and none could be inferred from the base input job. "
            "Set MODEL_SELECTOR or MODEL_SELECTORS."
        )
    parallel_units = truthy(args.parallel_units, default=True)
    submit_workers, submit_worker_source = resolve_submit_workers(args.submit_workers)
    print(
        f"submission workers: {submit_workers} ({submit_worker_source})",
        file=sys.stderr,
    )
    auto_merge = truthy(args.auto_merge, default=True)
    auto_attach = truthy(args.auto_attach, default=True)
    attach_merge_with_latest = truthy(os.environ.get("KFLOW_ATTACH_MERGE_WITH_LATEST", "true"), default=True)
    requested_attach_mode = str(os.environ.get("ATTACH_OUTPUT_MODE", "delta")).strip().lower()
    requested_delta_attach = requested_attach_mode in {"delta", "overlay", "delta_overlay"}
    previous_attached_job_for_base = "" if requested_delta_attach else env_first(
        "KFLOW_PREVIOUS_ATTACHED_OUTPUT_JOB",
        "KFLOW_LATEST_ATTACHED_OUTPUT_JOB",
    ).lstrip("#")
    if previous_attached_job_for_base == base_input_job:
        previous_attached_job_for_base = ""
    if (
        base_input_job
        and not previous_attached_job_for_base
        and not requested_delta_attach
        and not args.dry_run
        and token
    ):
        previous_attached_job_for_base = latest_attached_output_job(base_url, token, base_input_job)
    direct_merge_attach = (
        auto_attach
        and auto_merge
        and bool(base_input_job)
        and requested_delta_attach
        and all(check in DIRECT_MERGE_CHECKS for check in checks)
    )
    previous_attached_output_by_slot: dict[str, str] = {}
    previous_by_slot_raw = env_first(
        "KFLOW_PREVIOUS_ATTACHED_OUTPUT_BY_SLOT",
        "KFLOW_ATTACHED_OUTPUT_LATEST_BY_SLOT",
    )
    if direct_merge_attach and previous_by_slot_raw:
        try:
            parsed_by_slot = json.loads(previous_by_slot_raw)
        except json.JSONDecodeError as exc:
            raise SystemExit("KFLOW_PREVIOUS_ATTACHED_OUTPUT_BY_SLOT must be a JSON object.") from exc
        if not isinstance(parsed_by_slot, dict):
            raise SystemExit("KFLOW_PREVIOUS_ATTACHED_OUTPUT_BY_SLOT must be a JSON object.")
        previous_attached_output_by_slot = {
            attached_work_slot_key(slot): attached_output_ref(value)
            for slot, value in parsed_by_slot.items()
            if attached_work_slot_key(slot) and attached_output_ref(value)
        }
    elif direct_merge_attach and not args.dry_run and token:
        previous_attached_output_by_slot = latest_attached_output_jobs_by_slot(
            base_url,
            token,
            base_input_job,
        )
    submitter_fields = {
        "repo": args.repo_full_name,
        "branch": args.branch,
        "make_target": args.make_target,
        "docker_image": args.docker_image,
        "cpus": int(args.cpus),
        "memory": args.memory,
        "disk": args.disk,
        "remote_host": args.submitter or args.remote_host,
        "remote_user": args.remote_user,
        "remote_base_dir": remote_base_dir_value(
            args.remote_base_dir,
            args.remote_user,
            args.submitter or args.remote_host,
        ),
        "slot_requirements": args.slot_requirements,
    }
    submitter_fields = {key: value for key, value in submitter_fields.items() if str(value or "").strip()}

    submitted_groups: list[dict[str, Any]] = []
    registered_tasks: set[str] = set()

    for check in checks:
        for model in models:
            unit_job_ids: list[str] = []
            unit_specs = check_unit_specs(check, parallel_units)
            expected_unit_type, expected_units = expected_unit_ledger(unit_specs)
            profile_submit_env = (
                resolved_profile_env(profile_values_from_env())
                if check == "profile" else {}
            )
            is_hbase = check == "profile" and is_hbase_profile_mode(
                profile_submit_env.get("PROFILE_PARALLEL_MODE", "")
            )
            requested_prep_job = env_first("PROFILE_HBASE_PREP_JOB").lstrip("#")
            prep_job_id = ""
            unit_input_jobs = list(input_jobs)
            if is_hbase and requested_prep_job:
                if not base_input_job:
                    raise SystemExit("h-base profile submission requires the fitted base job first.")
                if not args.dry_run:
                    prep_record = api_job(base_url, token, requested_prep_job)
                    prep_report = str(
                        prep_record.get("report_code") or prep_record.get("task_name") or ""
                    )
                    if "profile-h-base-prep" not in prep_report:
                        raise SystemExit(
                            f"PROFILE_HBASE_PREP_JOB={requested_prep_job} is not an h-base prep job."
                        )
                prep_job_id = requested_prep_job
                unit_input_jobs = [base_input_job, prep_job_id]
            elif is_hbase:
                if not base_input_job:
                    raise SystemExit("h-base profile submission requires the fitted base job first.")
                hessian_jobs = [
                    job.lstrip("#")
                    for job in split_values(env_first("PROFILE_HBASE_HESSIAN_JOBS"))
                ] or list(input_jobs[1:])
                hessian_jobs = list(dict.fromkeys(
                    job for job in hessian_jobs if job and job != base_input_job
                ))
                if not hessian_jobs:
                    raise SystemExit(
                        "h-base requires Hessian part/merge jobs after the base job or in "
                        "PROFILE_HBASE_HESSIAN_JOBS."
                    )
                if args.dry_run:
                    base_internal_job_id = f"DRY-base-{base_input_job}"
                else:
                    base_job_record = api_job(base_url, token, base_input_job)
                    base_internal_job_id = str(base_job_record.get("id") or "").strip()
                    if not base_internal_job_id:
                        raise RuntimeError(
                            f"Kflow base job {base_input_job} did not expose its internal job ID."
                        )
                prep_task = f"{args.task_prefix}-profile-h-base-prep"
                prep_title = args.job_title or f"h-base prep: {model}"
                prep_description = args.job_description or (
                    f"Validate the native Hessian/gradient and prepare profile starts for {model}."
                )
                prep_env = {
                    "CHECK_TYPE": "profile",
                    "MODEL_SELECTOR": model,
                    "KFLOW_JOB_TITLE": prep_title,
                    "KFLOW_JOB_DESCRIPTION": prep_description,
                    "MODEL_SOURCE_REPO": args.model_source_repo,
                    "MODEL_SOURCE_REF": args.model_source_ref,
                    "MODEL_SOURCE_PATH": args.model_source_path,
                    "PROGRAM_PATH": args.program_path,
                    "FLOW_GROUP": args.flow_group,
                    **flow_metadata_env(),
                    **profile_submit_env,
                    "PROFILE_HBASE_ENABLED": "true",
                    "PROFILE_HBASE_ROLE": "prep",
                    "PROFILE_HBASE_BASE_JOB_ID": base_internal_job_id,
                    "PROFILE_HBASE_HESSIAN_JOBS": " ".join(hessian_jobs),
                    "CHECK_COMPACT_OUTPUTS": "true",
                    "CHECK_FAIL_ON_FAILED_UNITS": "false",
                    "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
                    "MFCL_LIVE_LOG": os.environ.get("MFCL_LIVE_LOG", "true"),
                    "TUNA_FLOW_RUNTIME_UPDATE": os.environ.get("TUNA_FLOW_RUNTIME_UPDATE", "always"),
                    "KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS": os.environ.get("KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS", "0"),
                    "KFLOW_RUNTIME_PACKAGES": os.environ.get("KFLOW_RUNTIME_PACKAGES", DEFAULT_RUNTIME_PACKAGES),
                    "KFLOW_REPO_RUNTIME_PACKAGES": os.environ.get("KFLOW_REPO_RUNTIME_PACKAGES", "none"),
                    "KFLOW_REPO_RUNTIME_UPDATE": os.environ.get("KFLOW_REPO_RUNTIME_UPDATE", "always"),
                    "KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES": os.environ.get("KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES", "true"),
                    "KFLOW_RUNTIME_GITHUB_AUTH": os.environ.get("KFLOW_RUNTIME_GITHUB_AUTH", "true"),
                    "KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME": os.environ.get("KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME", "true"),
                }
                prep_inputs = list(dict.fromkeys([base_input_job, *hessian_jobs]))
                prep_payload: dict[str, Any] = {
                    **submitter_fields,
                    "env": {key: value for key, value in prep_env.items() if value not in (None, "")},
                    "title": prep_title,
                    "description": prep_description,
                    "input_jobs": prep_inputs,
                    "metadata": {
                        "flow_group": args.flow_group,
                        "check_type": "profile-h-base-prep",
                        "model_selector": model,
                        "base_job": base_input_job,
                        "base_internal_job_id": base_internal_job_id,
                        "hessian_jobs": hessian_jobs,
                        "input_jobs": prep_inputs,
                        "profile_parallel_mode": "h-base",
                    },
                    "tags": {
                        "stage": "checks",
                        "flow": args.flow_group,
                        "check_type": "profile-h-base-prep",
                        "model": model,
                    },
                }
                if args.dry_run:
                    print(json.dumps({"task": prep_task, "payload": prep_payload}, indent=2, sort_keys=True))
                    prep_job_id = f"DRY-profile-h-base-prep-{model}"
                else:
                    prep_response = api_json("POST", f"{base_url}/api/job/{prep_task}", token, prep_payload)
                    prep_job = prep_response.get("job", prep_response)
                    prep_job_id = str(
                        prep_job.get("job_number") or prep_job.get("number") or
                        prep_job.get("code") or prep_job.get("id") or ""
                    )
                    if not prep_job_id:
                        raise RuntimeError("Kflow did not return an h-base prep job ID.")
                    print(f"submitted {prep_task} {model}: job {prep_job_id}")
                unit_input_jobs = [base_input_job, prep_job_id]
            unit_submissions: list[tuple[int, str, dict[str, Any]]] = []
            for unit in unit_specs:
                task = (
                    f"{args.task_prefix}-profile-h-base"
                    if is_hbase else f"{args.task_prefix}-{check}"
                )
                if not args.dry_run:
                    ensure_check_task_registered(
                        base_url,
                        token,
                        task,
                        check,
                        submitter_fields,
                        registered_tasks,
                    )
                unit_label = str(unit.get("label") or "").strip()
                if check == "model-bundle":
                    title = args.job_title or f"MFCL bundle: {model}"
                    description = args.job_description or f"Build a portable MFCL run bundle zip for {model}."
                    runtime_packages_default = "none"
                    repo_runtime_packages_default = "none"
                    repo_runtime_update_default = "never"
                else:
                    title = args.job_title or (
                        f"{check} {unit_label}: {model}" if unit_label else f"{check}: {model}"
                    )
                    description = args.job_description or (
                        f"Run {check} {unit_label} check for {model}."
                        if unit_label else
                        f"Run {check} check for {model}."
                    )
                    runtime_packages_default = DEFAULT_RUNTIME_PACKAGES
                    repo_runtime_packages_default = "none"
                    repo_runtime_update_default = "always"
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
                    **flow_metadata_env(),
                    "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
                    "MFCL_LIVE_LOG": os.environ.get("MFCL_LIVE_LOG", "true"),
                    "TUNA_FLOW_RUNTIME_UPDATE": os.environ.get("TUNA_FLOW_RUNTIME_UPDATE", "always"),
                    "KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS": os.environ.get("KFLOW_RUNTIME_UPDATE_INTERVAL_HOURS", "0"),
                    "KFLOW_RUNTIME_PACKAGES": os.environ.get("KFLOW_RUNTIME_PACKAGES", runtime_packages_default),
                    "KFLOW_REPO_RUNTIME_PACKAGES": os.environ.get("KFLOW_REPO_RUNTIME_PACKAGES", repo_runtime_packages_default),
                    "KFLOW_REPO_RUNTIME_UPDATE": os.environ.get("KFLOW_REPO_RUNTIME_UPDATE", repo_runtime_update_default),
                    "KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES": os.environ.get("KFLOW_RUNTIME_REQUIRE_PRIVATE_PACKAGES", "true"),
                    "KFLOW_RUNTIME_GITHUB_AUTH": os.environ.get("KFLOW_RUNTIME_GITHUB_AUTH", "true"),
                    "KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME": os.environ.get("KFLOW_FORWARD_GITHUB_TOKEN_TO_RUNTIME", "true"),
                }
                env_prefixes = (
                    "BET_", "JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "ASPM_", "BUNDLE_",
                    "SELFTEST_", "MFK_", "CHECK_", "selftest_",
                )
                passthrough_env = {"TRIGGER_NEXT"}
                protected_env = {
                    "CHECK_TYPE",
                    "CHECK_EXPECTED_UNIT_TYPE",
                    "CHECK_EXPECTED_UNITS",
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
                    env.setdefault(
                        "SELFTEST_TAG_SIMULATION",
                        os.environ.get(
                            "SELFTEST_TAG_SIMULATION",
                            os.environ.get("CHECK_SELFTEST_TAG_SIMULATION", "conditional_postmixing"),
                        ),
                    )
                    env.setdefault(
                        "SELFTEST_PROGRAM_PATH",
                        os.environ.get(
                            "SELFTEST_PROGRAM_PATH",
                            os.environ.get("PROGRAM_PATH", "/home/mfcl/mfclo64"),
                        ),
                    )
                    env.setdefault(
                        "SELFTEST_REFIT_CONVERGENCE",
                        os.environ.get("SELFTEST_REFIT_CONVERGENCE", DEFAULT_SELFTEST_REFIT_CONVERGENCE),
                    )
                    # A split self-test unit must surface an incomplete native
                    # replicate as a failed Kflow job. A completed PAR remains
                    # successful even when its convergence flag is false; the
                    # viewer filters that diagnostic result later. Keep an
                    # explicit caller override, but do not depend on the
                    # registered task default being current.
                    env["CHECK_FAIL_ON_FAILED_UNITS"] = (
                        str(env.get("CHECK_FAIL_ON_FAILED_UNITS") or "").strip()
                        or "true"
                    )
                env.update(unit.get("env", {}))
                if is_hbase:
                    env.update({
                        "PROFILE_HBASE_ENABLED": "true",
                        "PROFILE_HBASE_ROLE": "scalar",
                        "PROFILE_HBASE_PREP_JOB": prep_job_id,
                    })
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
                    **check_task_resources(check, submitter_fields),
                    "env": env,
                    "title": title,
                    "description": description,
                    "input_jobs": unit_input_jobs,
                    "metadata": {
                        "flow_group": args.flow_group,
                        "job_title": title,
                        "job_description": description,
                        "check_type": check,
                        "model_selector": model,
                        "input_jobs": unit_input_jobs,
                        "parallel_units": parallel_units,
                        **unit_metadata,
                    },
                    "tags": tags,
                }
                if args.dry_run:
                    print(json.dumps({"task": task, "payload": payload}, indent=2, sort_keys=True))
                    unit_job_ids.append(f"DRY-{check}-{model}-{check_unit or 'unit'}")
                    continue
                unit_submissions.append((len(unit_submissions), task, payload))

            def submit_unit(spec: tuple[int, str, dict[str, Any]]) -> tuple[int, str, str]:
                index, task_name, unit_payload = spec
                response = api_json(
                    "POST",
                    f"{base_url}/api/job/{task_name}",
                    token,
                    unit_payload,
                )
                job = response.get("job", response)
                code = str(
                    job.get("job_number")
                    or job.get("number")
                    or job.get("code")
                    or job.get("id")
                    or "?"
                )
                return index, task_name, code

            use_parallel_submission = (
                parallel_units
                and check in PARALLEL_SUBMISSION_CHECKS
                and submit_workers > 1
                and len(unit_submissions) > 1
            )
            submitted_units: list[tuple[int, str, str]] = []
            if use_parallel_submission:
                workers = min(submit_workers, len(unit_submissions))
                with ThreadPoolExecutor(max_workers=workers) as executor:
                    futures = {
                        executor.submit(submit_unit, spec): spec[0]
                        for spec in unit_submissions
                    }
                    for future in as_completed(futures):
                        submitted_units.append(future.result())
            else:
                submitted_units = [submit_unit(spec) for spec in unit_submissions]

            for _, task_name, code in sorted(submitted_units):
                if code != "?":
                    unit_job_ids.append(code)
                print(f"submitted {task_name} {model}: job {code}")
            submitted_groups.append(
                {
                    "check": check,
                    "model": model,
                    "unit_job_ids": unit_job_ids,
                    "final_job_ids": list(unit_job_ids),
                    "expected_unit_type": expected_unit_type,
                    "expected_units": expected_units,
                    "is_hbase": is_hbase,
                    "prep_job_id": prep_job_id,
                }
            )

    # All units above and all diagnostic-specific merges below are independent.
    # Each merge rebuilds from the stable original fit and only its own units.
    for group in submitted_groups:
        check = group["check"]
        merge_check = merge_check_for(check)
        unit_job_ids = group["unit_job_ids"]
        if not auto_merge or not merge_check or not unit_job_ids:
            continue
        model = group["model"]
        is_hbase = bool(group.get("is_hbase"))
        task = (
            f"{args.task_prefix}-profile-h-base-merge"
            if is_hbase else f"{args.task_prefix}-{merge_check}"
        )
        if not args.dry_run:
            ensure_check_task_registered(
                base_url,
                token,
                task,
                merge_check,
                submitter_fields,
                registered_tasks,
            )
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
            **flow_metadata_env(),
            "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
            "MFCL_LIVE_LOG": os.environ.get("MFCL_LIVE_LOG", "true"),
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
            if key.startswith(("BET_", "JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "ASPM_", "BUNDLE_", "SELFTEST_", "MFK_", "CHECK_", "selftest_")) or key in {"TRIGGER_NEXT"} or key == "program_path":
                env[key] = value
        expected_unit_type = str(group.get("expected_unit_type") or "").strip()
        expected_units = [
            str(value).strip()
            for value in group.get("expected_units") or []
            if str(value).strip()
        ]
        env.pop("CHECK_EXPECTED_UNIT_TYPE", None)
        env.pop("CHECK_EXPECTED_UNITS", None)
        if expected_unit_type and expected_units:
            env["CHECK_EXPECTED_UNIT_TYPE"] = expected_unit_type
            env["CHECK_EXPECTED_UNITS"] = " ".join(expected_units)
        profile_merge_env: dict[str, str] = {}
        if check == "profile":
            profile_merge_env = resolved_profile_env(profile_values_from_env())
            profile_merge_env.pop("PROFILE_CHAIN_SIDE", None)
            env.update(profile_merge_env)
            if is_hbase:
                env.update({
                    "PROFILE_HBASE_ENABLED": "true",
                    "PROFILE_HBASE_ROLE": "merge",
                    "PROFILE_HBASE_PREP_JOB": str(group.get("prep_job_id") or ""),
                    "MODEL_BASE_INPUT_JOB": base_input_job,
                    "BASE_MODEL_JOB": base_input_job,
                    "MODEL_ORIGINAL_BASE_INPUT_JOB": base_input_job,
                    "CHECK_INPUT_JOBS": " ".join(unit_job_ids),
                })
        if check == "hessian":
            env["CHECK_TYPE"] = "hessian_merge"

        if direct_merge_attach:
            env.update({
                "ATTACH_OUTPUT_MODE": "delta",
                "ATTACH_CHECK_TYPES": check,
                "ATTACH_UPDATED_CHECK_TYPES": check,
                "MODEL_BASE_INPUT_JOB": base_input_job,
                "BASE_MODEL_JOB": base_input_job,
                "MODEL_ORIGINAL_BASE_INPUT_JOB": base_input_job,
                "CHECK_INPUT_JOBS": " ".join(unit_job_ids),
            })
        previous_merge_jobs = (
            previous_check_merge_jobs(base_url, token, previous_attached_job_for_base, check)
            if previous_attached_job_for_base and not args.dry_run and token
            else []
        )
        input_history = []
        if previous_merge_jobs:
            input_history.append(
                {
                    "label": f"Previous {check} merge",
                    "jobs": previous_merge_jobs,
                }
            )
        if previous_attached_job_for_base:
            input_history.append(
                {
                    "label": "Previous attached output",
                    "jobs": [previous_attached_job_for_base],
                }
            )
        direct_attach_metadata: dict[str, Any] = {}
        direct_attach_tags: dict[str, Any] = {}
        if direct_merge_attach:
            attached_work_slot = diagnostic_attached_work_slot(model, check)
            same_slot_predecessor = previous_attached_output_by_slot.get(
                attached_work_slot_key(attached_work_slot),
                "",
            )
            direct_attach_metadata = {
                "base_job": base_input_job,
                "original_base_job": base_input_job,
                "attach_base_input_job": base_input_job,
                "check_input_jobs": list(unit_job_ids),
                "attach_check_types": [check],
                "attached_check_types": [check],
                "attached_updated_check_types": [check],
                "attached_output_overlay": True,
                "attached_output_overlay_mode": "diagnostics_with_payload",
                "attached_output_overlay_preserve_payload": True,
                "attached_output_overlay_replace_payload": True,
                "attached_output_overlay_replace_names": [check],
                "attached_work_parent_job": base_input_job,
                "attached_work_latest": True,
                "attached_work_group": f"{args.flow_group}:{model}:diagnostics",
                # Diagnostic-specific slots keep all independent overlays
                # visible and prevent one check type from replacing another.
                "attached_work_slot": attached_work_slot,
                "attached_work_headline": os.environ.get("KFLOW_ATTACHED_WORK_HEADLINE", "Diagnostics"),
                "attached_work_label": f"{model} {check} diagnostics",
                "attached_work_summary": (
                    f"Merged {check} diagnostic delta attached directly to the base model output."
                ),
                "attached_work_role": "updated output",
                "direct_merge_attach": True,
                "attach_output_mode": "delta",
                "overlay_base_input_job": base_input_job,
                "previous_attached_output_job": same_slot_predecessor,
                "same_slot_predecessor_job": same_slot_predecessor,
                "independent_diagnostic_merge": True,
            }
            direct_attach_tags = {"base_job": base_input_job, "attached_output_overlay": "true"}

        merge_input_jobs = list(unit_job_ids)
        if direct_merge_attach or is_hbase:
            merge_input_jobs = list(dict.fromkeys([base_input_job, *unit_job_ids]))

        payload = {
            **submitter_fields,
            **check_task_resources(merge_check, submitter_fields),
            "env": {key: value for key, value in env.items() if value not in (None, "")},
            "title": title,
            "description": description,
            "input_jobs": merge_input_jobs,
            "metadata": {
                "flow_group": args.flow_group,
                "job_title": title,
                "job_description": description,
                "check_type": merge_check,
                "merged_check_type": check,
                "model_selector": model,
                "input_jobs": merge_input_jobs,
                "parallel_units": parallel_units,
                "auto_merge": True,
                "allow_failed_input_jobs": True,
                "nested_work_group": check,
                **({
                    "check_expected_unit_type": expected_unit_type,
                    "check_expected_units": expected_units,
                } if expected_unit_type and expected_units else {}),
                **({
                    "profile_name": profile_merge_env.get("PROFILE_NAME", ""),
                    "profile_preset": profile_merge_env.get("PROFILE_PRESET", ""),
                    "profile_repair_strictness": profile_merge_env.get("PROFILE_REPAIR_STRICTNESS", ""),
                    "profile_execution_mode": profile_merge_env.get("PROFILE_EXECUTION_MODE", ""),
                    "profile_parallel_mode": profile_merge_env.get("PROFILE_PARALLEL_MODE", ""),
                    "profile_doitall_penalty": profile_merge_env.get("PROFILE_DOITALL_PENALTY", ""),
                    "profile_doitall_script": profile_merge_env.get("PROFILE_DOITALL_SCRIPT", ""),
                    "profile_expected_values": profile_merge_env.get("PROFILE_EXPECTED_VALUES", ""),
                    "profile_spec_version": profile_merge_env.get("PROFILE_SPEC_VERSION", ""),
                } if check == "profile" else {}),
                "previous_attached_output_job": previous_attached_job_for_base,
                "previous_check_merge_jobs": previous_merge_jobs,
                "input_history": input_history,
                **direct_attach_metadata,
            },
            "tags": {
                "stage": "checks",
                "flow": args.flow_group,
                "check_type": merge_check,
                "model": model,
                "merge_for": check,
                **direct_attach_tags,
            },
        }
        if args.dry_run:
            print(json.dumps({"task": task, "payload": payload}, indent=2, sort_keys=True))
            merge_job_ref = f"DRY-{merge_check}-{model}-merge"
            group["final_job_ids"] = [merge_job_ref]
            continue
        response = api_json("POST", f"{base_url}/api/job/{task}", token, payload)
        job = response.get("job", response)
        code = job.get("job_number") or job.get("number") or job.get("code") or job.get("id") or "?"
        if code and code != "?":
            group["final_job_ids"] = [str(code)]
        elif direct_merge_attach:
            raise RuntimeError(
                f"{task} did not return a job reference for its diagnostic attachment."
            )
        print(f"submitted {task} {model}: job {code}")

    if auto_attach and base_input_job and not requested_delta_attach:
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
            previous_attached_job = previous_attached_job_for_base
            attach_base_input_job = base_input_job
            if attach_merge_with_latest and not args.dry_run and token:
                if previous_attached_job and previous_attached_job not in final_job_ids:
                    attach_base_input_job = previous_attached_job
            attach_input_jobs = [base_input_job]
            if previous_attached_job and previous_attached_job not in attach_input_jobs:
                attach_input_jobs.append(previous_attached_job)
            attach_input_jobs.extend(job_id for job_id in final_job_ids if job_id not in attach_input_jobs)
            task = f"{args.task_prefix}-attach-checks"
            title = f"diagnostics update: {model}"
            description = f"Attach completed model-check outputs to the base job for {model}."
            env = {
                "CHECK_TYPE": "attach-checks",
                "MODEL_SELECTOR": model,
                "MODEL_BASE_INPUT_JOB": attach_base_input_job,
                "BASE_MODEL_JOB": attach_base_input_job,
                "MODEL_ORIGINAL_BASE_INPUT_JOB": base_input_job,
                "CHECK_INPUT_JOBS": " ".join(final_job_ids),
                "ATTACH_CHECK_TYPES": checks_text,
                "ATTACH_OUTPUT_MODE": os.environ.get("ATTACH_OUTPUT_MODE", "delta"),
                "KFLOW_JOB_TITLE": title,
                "KFLOW_JOB_DESCRIPTION": description,
                "MODEL_SOURCE_REPO": args.model_source_repo,
                "MODEL_SOURCE_REF": args.model_source_ref,
                "MODEL_SOURCE_PATH": args.model_source_path,
                "PROGRAM_PATH": args.program_path,
                "FLOW_GROUP": args.flow_group,
                **flow_metadata_env(),
                "KFLOW_RUNTIME_UPDATE": os.environ.get("KFLOW_RUNTIME_UPDATE", "always"),
                "MFCL_LIVE_LOG": os.environ.get("MFCL_LIVE_LOG", "true"),
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
                if key in {
                    "CHECK_TYPE", "CHECK_EXPECTED_UNIT_TYPE", "CHECK_EXPECTED_UNITS",
                    "MODEL_SELECTOR", "KFLOW_JOB_TITLE", "KFLOW_JOB_DESCRIPTION",
                }:
                    continue
                if key.startswith(("BET_", "JITTER_", "RETRO_", "HESSIAN_", "PROFILE_", "ASPM_", "BUNDLE_", "SELFTEST_", "MFK_", "CHECK_", "selftest_")) or key in {"TRIGGER_NEXT"} or key == "program_path":
                    env[key] = value
            attach_output_mode = str(env.get("ATTACH_OUTPUT_MODE") or "delta").strip().lower()
            attach_is_delta = attach_output_mode in {"delta", "overlay", "delta_overlay"}
            payload = {
                **submitter_fields,
                "env": {key: value for key, value in env.items() if value not in (None, "")},
                "title": title,
                "description": description,
                "input_jobs": attach_input_jobs,
                "metadata": {
                    "flow_group": args.flow_group,
                    "job_title": title,
                    "job_description": description,
                    "check_type": "attach-checks",
                    "model_selector": model,
                    "base_job": base_input_job,
                    "input_jobs": attach_input_jobs,
                    "check_input_jobs": final_job_ids,
                    "attach_check_types": item["checks"],
                    "previous_attached_output_job": previous_attached_job,
                    "attach_base_input_job": attach_base_input_job,
                    "attached_work_parent_job": base_input_job,
                    "attached_work_latest": True,
                    "attached_output_overlay": attach_is_delta,
                    "attached_output_overlay_mode": (
                        "diagnostics_with_payload" if attach_is_delta else "standalone"
                    ),
                    "attached_output_overlay_replace_payload": attach_is_delta,
                    "attached_output_overlay_replace_names": (
                        DIAGNOSTIC_OVERLAY_REPLACE_NAMES if attach_is_delta else []
                    ),
                    "attach_output_mode": attach_output_mode,
                    "attached_work_group": f"{args.flow_group}:{model}:diagnostics",
                    "attached_work_headline": os.environ.get("KFLOW_ATTACHED_WORK_HEADLINE", "Diagnostics"),
                    "attached_work_label": f"{model} diagnostics",
                    "attached_work_summary": "Latest model-check outputs attached to the base job output bundle.",
                    "attached_work_role": "updated output",
                    "auto_attach": True,
                    "allow_failed_input_jobs": True,
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
