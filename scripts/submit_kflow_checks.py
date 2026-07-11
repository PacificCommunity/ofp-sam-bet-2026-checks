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
    "mfclkit=PacificCommunity/ofp-sam-mfclkit@c6614afae6ac3455c29f2d484c0cc1a94353def2,"
    "mfclshiny=PacificCommunity/mfclshiny@65cf0aff15f5fd85ce96fda8c5bd89e9e2a6afe7"
)

DEFAULT_PROFILE_VALUES = [float(value) for value in range(60, 145, 5)]
DEFAULT_PROFILE_CENTER = "100"
DEFAULT_JITTER_SEEDS = ["1", "2"]
DEFAULT_RETRO_PEELS = ["1", "2", "3", "4", "5"]
DEFAULT_SELFTEST_REPS = ["1", "2"]
MAX_R_INTEGER = 2_147_483_647
DIAGNOSTIC_OVERLAY_REPLACE_NAMES = [
    "jitter",
    "retro",
    "hessian",
    "profile",
    "selftest",
    "aspm",
    "projection",
]
DIRECT_MERGE_CHECKS = tuple(MERGE_CHECKS)


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
    raw = env_first("MFK_PROFILE_VALUES", "PROFILE_VALUES", "MFK_SCALAR")
    if not raw:
        return list(DEFAULT_PROFILE_VALUES)
    return numeric_values(raw)


def resolved_profile_env(values: list[float] | None = None) -> dict[str, str]:
    """Resolve one profile contract for side jobs and their merge job."""
    values = list(profile_values_from_env() if values is None else values)
    center_raw = env_first("MFK_PROFILE_CENTER", "PROFILE_CENTER") or DEFAULT_PROFILE_CENTER
    try:
        center = float(center_raw)
    except ValueError as exc:
        raise SystemExit(f"PROFILE_CENTER must be numeric, got {center_raw!r}.") from exc

    profile_type = env_first("MFK_PROFILE_TYPE", "PROFILE_TYPE") or "quantity"
    profile_name = env_first("MFK_PROFILE_NAME", "PROFILE_NAME", "MFK_PROFILE") or "adult_biomass"
    profile_label = env_first("MFK_PROFILE_LABEL", "PROFILE_LABEL") or profile_name
    quantity = env_first("MFK_PROFILE_QUANTITY", "PROFILE_QUANTITY") or "avg_bio"
    quantity_type = env_first("MFK_PROFILE_QUANTITY_TYPE", "PROFILE_QUANTITY_TYPE") or "2"

    # Match profile/kflow.yaml: the generic staged native profile is the
    # ordinary default.  The older BET schedule remains selectable explicitly
    # with PROFILE_STYLE=bet or PROFILE_PRESET=adaptive.
    legacy_style = env_first("PROFILE_STYLE", "PROFILE_RUNNER") or "three_stage"
    preset = env_first("MFK_PROFILE_PRESET", "PROFILE_PRESET")
    if not preset:
        style_key = legacy_style.strip().lower().replace("-", "_")
        preset = {
            "bet": "adaptive",
            "ramp": "adaptive",
            "quantity_ramp": "adaptive",
            "adaptive": "adaptive",
            "three_stage": "three_stage",
            "manual": "manual_7stage",
            "manual_7stage": "manual_7stage",
            # The runner maps this compatibility value to a one-stage plan.
            "simple": "three_stage",
        }.get(style_key, style_key)
    preset_key = preset.strip().lower().replace("-", "_")
    preset = {
        "john": "three_stage",
        "john_3stage": "three_stage",
        "native_3stage": "three_stage",
        "standard_3stage": "three_stage",
        "3stage": "three_stage",
        "manual": "manual_7stage",
        "bet": "adaptive",
        "ramp": "adaptive",
        "quantity_ramp": "adaptive",
    }.get(preset_key, preset_key)
    if preset not in {"three_stage", "manual_7stage", "adaptive"}:
        raise SystemExit(
            f"Unsupported profile preset {preset!r}; use three_stage, manual_7stage, or adaptive."
        )

    preset_defaults = {
        "three_stage": ("100000 1000000 10000000", "50 50 2000"),
        "manual_7stage": (
            "100000 1000000 10000000 10000000 10000000 10000000 10000000",
            "15 25 25 1000 100 500 1000",
        ),
        # Preserve the established BET Kflow adaptive schedule.
        "adaptive": ("50000 500000 5000000", "15 25 25 500 500 200"),
    }
    default_penalties, default_reps = preset_defaults[preset]

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

    resolved = {
        "PROFILE_SPEC_VERSION": "mfclkit.quantity-profile.v2",
        "PROFILE_TYPE": profile_type,
        "PROFILE_NAME": profile_name,
        "PROFILE_LABEL": profile_label,
        "PROFILE_QUANTITY": quantity,
        "PROFILE_QUANTITY_TYPE": quantity_type,
        "PROFILE_VALUES": " ".join(format_number(value) for value in values),
        "PROFILE_EXPECTED_VALUES": " ".join(format_number(value) for value in expected),
        "PROFILE_CENTER": format_number(center),
        "PROFILE_PRESET": preset,
        "PROFILE_STYLE": legacy_style,
        "PROFILE_PARALLEL_MODE": env_first("PROFILE_PARALLEL_MODE") or "chains",
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
        "PROFILE_JAGGED_TOLERANCE": env_first(
            "MFK_PROFILE_JAGGED_TOLERANCE", "PROFILE_JAGGED_TOLERANCE",
        ) or "0.1",
    }
    return {key: value for key, value in resolved.items() if str(value).strip()}


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
            common_env = resolved_profile_env(values)
            return [{
                "label": "",
                "env": common_env,
                "metadata": {
                    "profile_name": common_env["PROFILE_NAME"],
                    "profile_preset": common_env["PROFILE_PRESET"],
                    "profile_expected_values": common_env["PROFILE_EXPECTED_VALUES"],
                },
            }]
        return [{"label": "", "env": {}, "metadata": {}}]

    if check_key == "profile":
        values = profile_values_from_env()
        common_env = resolved_profile_env(values)
        profile_name = common_env["PROFILE_NAME"]
        label_name = profile_name if profile_name and profile_name != "profile" else "scalar"
        mode = common_env["PROFILE_PARALLEL_MODE"].strip().lower() or "chains"
        if mode in {"chain", "chains", "left-right", "left_right", "upstream-downstream", "upstream_downstream"}:
            center = common_env["PROFILE_CENTER"]
            chains = split_profile_chains(values, center)
            return [
                {
                    "label": f"{side} chain",
                    "env": {
                        **common_env,
                        "PROFILE_VALUES": " ".join(format_number(value) for value in chain_values),
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
                        "profile_expected_values": common_env["PROFILE_EXPECTED_VALUES"],
                        "profile_chain_values": " ".join(format_number(value) for value in chain_values),
                    },
                }
                for side, chain_values in chains.items()
            ]
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


def api_get_json(url: str, token: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
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

    checks = []
    for raw_check in split_values(args.checks):
        check = normalize_check_name(raw_check)
        if check and check not in checks:
            checks.append(check)
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
    attach_merge_with_latest = truthy(os.environ.get("KFLOW_ATTACH_MERGE_WITH_LATEST", "true"), default=True)
    requested_attach_mode = str(os.environ.get("ATTACH_OUTPUT_MODE", "delta")).strip().lower()
    requested_delta_attach = requested_attach_mode in {"delta", "overlay", "delta_overlay"}
    base_input_job = input_jobs[0] if input_jobs else ""
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
        "remote_host": args.submitter or args.remote_host,
        "remote_user": args.remote_user,
        "remote_base_dir": remote_base_dir_value(
            args.remote_base_dir,
            args.remote_user,
            args.submitter or args.remote_host,
        ),
    }
    submitter_fields = {key: value for key, value in submitter_fields.items() if str(value or "").strip()}

    submitted_groups: list[dict[str, Any]] = []

    for check in checks:
        for model in models:
            unit_job_ids: list[str] = []
            unit_specs = check_unit_specs(check, parallel_units)
            expected_unit_type, expected_units = expected_unit_ledger(unit_specs)
            for unit in unit_specs:
                task = f"{args.task_prefix}-{check}"
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
                    "expected_unit_type": expected_unit_type,
                    "expected_units": expected_units,
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
            **flow_metadata_env(),
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
        if direct_merge_attach:
            merge_input_jobs = list(dict.fromkeys([base_input_job, *unit_job_ids]))

        payload = {
            **submitter_fields,
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
