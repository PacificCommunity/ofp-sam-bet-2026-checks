import csv
import hashlib
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

    def attach(
        self,
        input_root: Path,
        output_dir: Path,
        check_job: str,
        check_type: str,
        output_mode: str | None = None,
    ) -> None:
        extra_env = {"ATTACH_OUTPUT_MODE": output_mode} if output_mode else {}
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
                **extra_env,
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

    def test_delta_attach_keeps_only_overlay_payload_and_updated_diagnostic(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            self.make_base_job(input_root)
            base_model = input_root / "base" / "outputs" / "models" / "model"
            for name in (
                "model.frq", "model.ini", "final.par", "plot.rep",
                "length.fit", "base-only.txt",
            ):
                (base_model / name).write_text(f"base {name}\n", encoding="utf-8")
            # The integration test disables package enrichment, so retain a
            # small prebuilt payload/manifest exactly as a real base job would.
            (base_model / "model_payload.rds").write_bytes(b"payload-placeholder")
            (base_model / "model_payload_manifest.json").write_text("{}\n", encoding="utf-8")
            write_csv(
                base_model / "model_payload_manifest.csv",
                [{"role": "model_payload", "file": "model_payload.rds"}],
            )
            old_retro = base_model / "retro" / "peel_1" / "old.txt"
            old_retro.parent.mkdir(parents=True)
            old_retro.write_text("old retrospective\n", encoding="utf-8")

            check_output = input_root / "merge" / "outputs"
            check_model = check_output / "checks" / "jitter" / "model"
            jitter_result = check_model / "jitter" / "jitter_seed_1" / "result.txt"
            jitter_result.parent.mkdir(parents=True)
            jitter_result.write_text("updated jitter\n", encoding="utf-8")
            write_csv(
                check_output / "checks" / "jitter" / "model-index.csv",
                [{
                    "check_type": "jitter",
                    "model_key": "model",
                    "step_id": "model",
                    "model_dir": "model",
                    "model_folder": "model",
                    "payload_role": "check_model_root",
                }],
            )
            write_csv(
                check_model / "check-summary.csv",
                [{"check_type": "jitter", "merge_status": "complete"}],
            )

            attached_output = root / "attached"
            self.attach(input_root, attached_output, "merge", "jitter", output_mode="delta")
            attached_model = attached_output / "models" / "model"

            self.assertTrue((attached_model / "model_payload.rds").is_file())
            self.assertTrue((attached_model / "model_payload_manifest.json").is_file())
            self.assertTrue((attached_model / "model_payload_manifest.csv").is_file())
            self.assertTrue((attached_model / "attached-checks-index.csv").is_file())
            self.assertTrue((attached_model / "jitter" / "jitter_seed_1" / "result.txt").is_file())
            self.assertTrue((attached_model / "retro" / "peel_1" / "old.txt").is_file())
            for name in (
                "model.frq", "model.ini", "final.par", "plot.rep",
                "length.fit", "base-only.txt",
            ):
                self.assertFalse((attached_model / name).exists(), name)

            self.assertFalse((attached_output / "base-model-candidates.csv").exists())
            self.assertFalse((attached_output / "check-model-candidates.csv").exists())
            self.assertTrue((attached_output / "model-index.csv").is_file())
            self.assertTrue((attached_output / "attach-output-manifest.csv").is_file())
            bundle = read_csv(attached_output / "attached-model-bundle.csv")[0]
            self.assertEqual(bundle["output_mode"], "delta")
            self.assertEqual(bundle["overlay_base_required"], "TRUE")
            inventory = read_csv(attached_output / "attach-output-manifest.csv")
            published = {row["relative_path"] for row in inventory}
            self.assertIn("models/model/model_payload.rds", published)
            self.assertIn("models/model/jitter/jitter_seed_1/result.txt", published)
            self.assertIn("models/model/retro/peel_1/old.txt", published)
            retained = {
                row["check_type"]
                for row in read_csv(attached_output / "attached-checks-index.csv")
            }
            self.assertEqual(retained, {"jitter", "retro"})
            self.assertFalse(any(path.endswith((".frq", ".ini", ".par", ".rep")) for path in published))
            excluded = {
                "attached-model-bundle.csv",
                "attached-model-bundle.rds",
                "attach-output-manifest.csv",
                "attach-output-manifest.rds",
            }
            self.assertTrue(excluded.isdisjoint(published))
            self.assertEqual(
                set(bundle["inventory_excluded_files"].split()),
                excluded,
            )
            self.assertEqual(int(bundle["n_published_files"]), len(inventory))
            self.assertEqual(
                int(float(bundle["published_bytes"])),
                sum(int(float(row["bytes"])) for row in inventory),
            )
            for row in inventory:
                path = attached_output / row["relative_path"]
                self.assertTrue(path.is_file(), row["relative_path"])
                self.assertEqual(int(float(row["bytes"])), path.stat().st_size)
                self.assertEqual(
                    row["md5"],
                    hashlib.md5(path.read_bytes()).hexdigest(),
                    row["relative_path"],
                )
                self.assertEqual(
                    set(row["inventory_excluded_files"].split()),
                    excluded,
                )

    def test_full_attach_mode_preserves_standalone_base_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            self.make_base_job(input_root)
            base_model = input_root / "base" / "outputs" / "models" / "model"
            (base_model / "base-only.txt").write_text("standalone\n", encoding="utf-8")

            check_output = input_root / "merge" / "outputs"
            check_model = check_output / "checks" / "jitter" / "model"
            result = check_model / "jitter" / "jitter_seed_1" / "result.txt"
            result.parent.mkdir(parents=True)
            result.write_text("updated jitter\n", encoding="utf-8")
            write_csv(
                check_output / "checks" / "jitter" / "model-index.csv",
                [{
                    "check_type": "jitter",
                    "model_key": "model",
                    "step_id": "model",
                    "model_dir": "model",
                    "model_folder": "model",
                    "payload_role": "check_model_root",
                }],
            )

            attached_output = root / "attached"
            self.attach(input_root, attached_output, "merge", "jitter", output_mode="full")
            self.assertTrue((attached_output / "models" / "model" / "base-only.txt").is_file())
            bundle = read_csv(attached_output / "attached-model-bundle.csv")[0]
            self.assertEqual(bundle["output_mode"], "full")
            self.assertEqual(bundle["overlay_base_required"], "FALSE")

    def test_direct_merge_delta_does_not_publish_duplicate_checks_tree(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output_dir = root / "outputs"
            check_model = output_dir / "checks" / "hessian" / "model"
            hessian_info = check_model / "hessian" / "hessian_info.rds"
            hessian_info.parent.mkdir(parents=True)
            hessian_info.write_bytes(b"hessian-placeholder")
            (check_model / "model_payload.rds").write_bytes(b"payload-placeholder")
            (check_model / "model_payload_manifest.json").write_text("{}\n", encoding="utf-8")
            write_csv(
                check_model / "model_payload_manifest.csv",
                [{"role": "model_payload", "file": "model_payload.rds"}],
            )
            (check_model / "final.par").write_text("base par\n", encoding="utf-8")
            (check_model / "model.frq").write_text("base frq\n", encoding="utf-8")

            expression = (
                'source("R/model_output_adapter.R"); '
                f'write_attached_model_output({str(check_model)!r}, {str(output_dir)!r}, '
                '"model", check_type="hessian", output_mode="delta")'
            )
            subprocess.run(
                ["Rscript", "-e", expression],
                cwd=ROOT,
                env={
                    **os.environ,
                    "CHECK_ENRICH_PAYLOADS": "false",
                    "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
                },
                text=True,
                capture_output=True,
                check=True,
            )

            published_model = output_dir / "models" / "model"
            self.assertFalse((output_dir / "checks").exists())
            self.assertTrue((published_model / "hessian" / "hessian_info.rds").is_file())
            self.assertTrue((published_model / "model_payload.rds").is_file())
            self.assertFalse((published_model / "final.par").exists())
            self.assertFalse((published_model / "model.frq").exists())

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
