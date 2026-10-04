#!/usr/bin/env python3
"""Check Make command routing without running R, MFCL or report builds."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / "ci/preserved-files.json").read_text())
REPOSITORY = MANIFEST.get("repository")
if REPOSITORY is None:
    # Ensemble retains its original guard schema, without repository metadata.
    if not (ROOT / "rr-test/standalone.zip").is_file() or not (ROOT / "rr-test/saved.py").is_file():
        raise RuntimeError("Unrecognised repository guard schema")
    REPOSITORY = "PacificCommunity/ofp-sam-bet-2026-ensemble"
NAME = REPOSITORY.rsplit("-", 1)[1]
TARGETS = {
    "diagnostic": ("help", "verify", "prepare", "rerun", "refit", "profiles", "aspm", "restore"),
    "ensemble": ("help", "verify", "rerun", "restore", "refit", "plan-refit"),
    "report": ("help", "verify", "rerun", "restore", "build"),
    "jitter": ("help", "verify", "native-check", "rerun", "prepare", "refit"),
    "selftest": ("help", "verify", "results", "rerun", "refit-plan", "refit"),
    "retrospective": ("help", "verify", "results", "rerun", "refit-plan", "refit"),
    "sensitivity": ("help", "verify", "results", "rerun", "restore", "refit"),
    "stepwise": ("rerun-help", "verify", "results", "rerun", "restore", "refit"),
    "checks": ("rerun-help", "verify", "test", "prepare", "rerun", "refit"),
}
CASES = {
    "diagnostic": "profile-75", "ensemble": "rrtest-005-rr1", "report": "reference",
    "jitter": "1", "sensitivity": "steepness-0.80", "stepwise": "20-Tau2Fixed",
    "checks": "jitter", "selftest": "1", "retrospective": "1",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    records = []
    with tempfile.TemporaryDirectory(prefix="bet-make-plan-") as folder:
        scratch = Path(folder)
        tools = scratch / "tools"
        tools.mkdir()
        # Legacy Make variables inspect R configuration even during -n.
        # Stub only that lookup; no R source or scientific calculation executes.
        rscript = tools / "Rscript"
        rscript.write_text("#!/bin/sh\nexit 0\n")
        rscript.chmod(0o755)
        native = scratch / "native"
        native.mkdir()
        engine = native / "mfclo64"
        engine.write_text("#!/bin/sh\necho 'MFCL must not execute in a Make plan check' >&2\nexit 99\n")
        engine.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""))
        env.pop("MAKEFLAGS", None)
        env.pop("MFLAGS", None)
        common = [f"INPUT={native}", f"MFCL={engine}", f"PROGRAM_PATH={engine}", "MODEL_SELECTOR=reader-example"]

        def run(target, output, dry=True, expected=0):
            case = "constant" if NAME == "diagnostic" and target == "aspm" else CASES[NAME]
            command = ["make", "--no-print-directory"] + (["-n"] if dry else [])
            command += [target, f"CASE={case}", f"OUT={output}", *common]
            result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=30)
            ok = result.returncode == 0 if expected == 0 else result.returncode != 0
            if not ok:
                raise RuntimeError(f"{target}: unexpected exit {result.returncode}\n{result.stdout}\n{result.stderr}")
            records.append({"target": target, "dry_run": dry, "exit": result.returncode, "expected_success": expected == 0})
            return result

        help_target = TARGETS[NAME][0]
        result = run(help_target, scratch / "unused", dry=False)
        if "make " not in result.stdout or "rerun" not in result.stdout:
            raise RuntimeError("Help does not show the reader entry points")
        for target in TARGETS[NAME][1:]:
            run(target, scratch / f"new-{target}")

        text = (ROOT / "Makefile").read_text()
        guard = "_check-output" if "\n_check-output:" in text else "_check-reader-inputs" if "\n_check-reader-inputs:" in text else None
        if guard:
            run(guard, scratch / "valid-new", dry=False)
            for invalid in ("", "relative-output", str(ROOT / "new-reader-output"), str(scratch)):
                run(guard, invalid, dry=False, expected=1)
        for target in TARGETS[NAME][1:]:
            if (scratch / f"new-{target}").exists():
                raise RuntimeError(f"Make plan unexpectedly created output for {target}")

    receipt = {"repository": REPOSITORY, "mode": "source_and_make_plans_only", "native_or_R_execution": False, "checks": records}
    if args.output:
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Make entry points passed: {NAME}, {len(records)} checks; no model execution.")


if __name__ == "__main__":
    main()
