import csv
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


@unittest.skipUnless(shutil.which("Rscript"), "Rscript is required")
class ExpectedUnitAttachmentTests(unittest.TestCase):
    def run_r(self, script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        process_env = {**os.environ, **(env or {})}
        return subprocess.run(
            ["Rscript", script],
            cwd=ROOT,
            env=process_env,
            text=True,
            capture_output=True,
            check=True,
        )

    def make_base_job(self, input_root: Path) -> None:
        base_output = input_root / "base" / "outputs"
        (base_output / "models" / "model").mkdir(parents=True)
        write_csv(
            base_output / "model-index.csv",
            [{
                "model_key": "model",
                "model_label": "model",
                "step_id": "model",
                "model_dir": "models/model",
                "model_folder": "model",
                "payload_role": "model_root",
            }],
        )

    def attach(self, input_root: Path, output_dir: Path, check_job: str, check_type: str) -> None:
        self.run_r(
            "R/attach_checks.R",
            {
                "MODEL_INPUT_ROOT": str(input_root),
                "OUTPUT_DIR": str(output_dir),
                "MODEL_SELECTOR": "model",
                "MODEL_BASE_INPUT_JOB": "base",
                "CHECK_INPUT_JOBS": check_job,
                "ATTACH_CHECK_TYPES": check_type,
                "CHECK_ENRICH_PAYLOADS": "false",
                "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
            },
        )

    def test_all_missing_merge_ledger_is_attachable(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            empty_inputs = root / "empty-inputs"
            empty_inputs.mkdir()
            input_root = root / "inputs"
            self.make_base_job(input_root)
            merge_output = input_root / "merge" / "outputs"

            self.run_r(
                "R/merge_check.R",
                {
                    "MODEL_INPUT_ROOT": str(empty_inputs),
                    "OUTPUT_DIR": str(merge_output),
                    "MODEL_SELECTOR": "model",
                    "CHECK_TYPE": "selftest-merge",
                    "CHECK_MERGE_TYPE": "selftest",
                    "CHECK_EXPECTED_UNIT_TYPE": "replicate",
                    "CHECK_EXPECTED_UNITS": "+001 2 1 02",
                    "CHECK_SMOKE_ONLY": "true",
                    "CHECK_ENRICH_PAYLOADS": "false",
                    "CHECK_COMPACT_OUTPUTS": "false",
                    "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
                },
            )

            merged_model = merge_output / "checks" / "selftest" / "model"
            merged_rows = read_csv(merged_model / "check-unit-status.csv")
            self.assertEqual([row["check_unit"] for row in merged_rows], ["1", "2"])
            self.assertEqual([row["run_status"] for row in merged_rows], ["missing", "missing"])
            summary = read_csv(merged_model / "check-summary.csv")[0]
            self.assertEqual(summary["n_expected_units"], "2")
            self.assertEqual(summary["n_missing_expected"], "2")
            self.assertEqual(summary["merge_status"], "incomplete")

            stale = (
                input_root / "base" / "outputs" / "models" / "model" /
                "selftest" / "rep_99" / "stale-success.txt"
            )
            stale.parent.mkdir(parents=True)
            stale.write_text("old successful output\n", encoding="utf-8")

            attached_output = root / "attached"
            self.attach(input_root, attached_output, "merge", "selftest")
            attached_rows = read_csv(
                attached_output / "models" / "model" / "selftest" / "check-unit-status.csv"
            )
            self.assertEqual(attached_rows, merged_rows)
            attached_selftest = attached_output / "models" / "model" / "selftest"
            self.assertFalse(
                (attached_selftest / "rep_99" / "stale-success.txt").exists()
            )
            for name in (
                "check-unit-status.rds",
                "check-summary.csv",
                "check-summary.rds",
                "check_manifest.csv",
                "check_manifest.rds",
            ):
                self.assertTrue((attached_selftest / name).is_file(), name)
            attached_index = read_csv(attached_output / "attached-checks-index.csv")
            self.assertEqual([row["check_type"] for row in attached_index], ["selftest"])
            self.assertEqual([row["attachment_state"] for row in attached_index], ["updated"])

    def test_partial_missing_ledger_is_copied_with_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            self.make_base_job(input_root)
            merge_output = input_root / "merge" / "outputs"
            model_dir = merge_output / "checks" / "jitter" / "model"
            (model_dir / "jitter" / "jitter_seed_1").mkdir(parents=True)
            (model_dir / "jitter" / "jitter_seed_1" / "result.txt").write_text(
                "completed\n",
                encoding="utf-8",
            )
            write_csv(
                merge_output / "checks" / "jitter" / "model-index.csv",
                [{
                    "check_type": "jitter",
                    "model_key": "model",
                    "step_id": "model",
                    "model_dir": "model",
                    "model_folder": "model",
                    "payload_role": "check_model_root",
                }],
            )
            status_rows = [
                {
                    "check_type": "jitter",
                    "check_unit_type": "seed",
                    "check_unit": "1",
                    "run_status": "completed",
                    "success": "TRUE",
                },
                {
                    "check_type": "jitter",
                    "check_unit_type": "seed",
                    "check_unit": "2",
                    "run_status": "missing",
                    "success": "FALSE",
                },
            ]
            write_csv(model_dir / "check-unit-status.csv", status_rows)
            write_csv(
                model_dir / "check-summary.csv",
                [{
                    "check_type": "jitter",
                    "expected_unit_type": "seed",
                    "expected_units": "1 2",
                    "n_expected_units": "2",
                    "n_missing_expected": "1",
                    "merge_status": "incomplete",
                }],
            )
            write_csv(
                model_dir / "check_manifest.csv",
                [{"check_type": "jitter", "model_key": "model"}],
            )

            attached_output = root / "attached"
            self.attach(input_root, attached_output, "merge", "jitter")
            attached_jitter = attached_output / "models" / "model" / "jitter"
            self.assertTrue((attached_jitter / "jitter_seed_1" / "result.txt").is_file())
            self.assertEqual(read_csv(attached_jitter / "check-unit-status.csv"), status_rows)

    def test_r_integer_parser_rejects_invalid_and_deduplicates(self):
        expression = (
            'source("R/model_output_adapter.R"); '
            'stopifnot(identical(positive_integer_values("+001 2 1 02", '
            'option="units"), c(1L, 2L))); '
            'bad <- c("0", "-1", "1.5", "2147483648", ",,,"); '
            'stopifnot(all(vapply(bad, function(x) inherits(try('
            'positive_integer_values(x, option="units"), silent=TRUE), "try-error"), logical(1L))))'
        )
        subprocess.run(
            ["Rscript", "-e", expression],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
