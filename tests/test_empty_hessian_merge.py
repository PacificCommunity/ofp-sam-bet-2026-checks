import csv
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("Rscript"), "Rscript is required")
class EmptyHessianMergeTests(unittest.TestCase):
    def test_all_missing_parts_produce_an_attachable_ledger(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            output_dir = root / "outputs"
            input_root.mkdir()
            env = {
                **os.environ,
                "MODEL_INPUT_ROOT": str(input_root),
                "OUTPUT_DIR": str(output_dir),
                "MODEL_SELECTOR": "model",
                "HESSIAN_NSPLIT": "2",
                "CHECK_SMOKE_ONLY": "true",
                "CHECK_COMPACT_OUTPUTS": "false",
                "CHECK_ENRICH_PAYLOADS": "false",
            }
            subprocess.run(
                ["Rscript", "R/merge_hessian.R"],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=True,
            )

            model_dir = output_dir / "checks" / "hessian" / "model"
            with (model_dir / "check-unit-status.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual([row["part"] for row in rows], ["1", "2"])
            self.assertTrue(all(row["run_status"] == "missing" for row in rows))
            self.assertTrue(all(row["success"] == "FALSE" for row in rows))

            with (model_dir / "check-summary.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                summary = next(csv.DictReader(handle))
            self.assertEqual(summary["n_units"], "2")
            self.assertEqual(summary["n_failed"], "2")
            self.assertEqual(summary["merge_status"], "incomplete_parts")
            self.assertTrue((output_dir / "checks-index.csv").is_file())

    def test_direct_delta_merge_rebuilds_from_base_before_pruning(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            output_dir = root / "outputs"

            base_model = input_root / "3001" / "outputs" / "models" / "model"
            base_model.mkdir(parents=True)
            payload_bytes = b"full-base-payload-placeholder"
            (base_model / "model_payload.rds").write_bytes(payload_bytes)
            (base_model / "model_payload_manifest.json").write_text("{}\n", encoding="utf-8")
            with (base_model / "model_payload_manifest.csv").open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=["role", "file"])
                writer.writeheader()
                writer.writerow({"role": "model_payload", "file": "model_payload.rds"})
            (base_model / "base-only.frq").write_text("base input\n", encoding="utf-8")
            prior_retro = base_model / "retro" / "peel_1" / "retro-result.txt"
            prior_retro.parent.mkdir(parents=True)
            prior_retro.write_text("prior attached retrospective\n", encoding="utf-8")
            with (base_model / "attached-checks-index.csv").open(
                "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(handle, fieldnames=["check_type", "attachment_state"])
                writer.writeheader()
                writer.writerow({"check_type": "retro", "attachment_state": "updated"})
            base_index = input_root / "3001" / "outputs" / "model-index.csv"
            with base_index.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["model_key", "model_label", "step_id", "model_dir", "model_folder"],
                )
                writer.writeheader()
                writer.writerow({
                    "model_key": "model",
                    "model_label": "model",
                    "step_id": "model",
                    "model_dir": "models/model",
                    "model_folder": "model",
                })

            part_dir = (
                input_root / "3287" / "outputs" / "checks" / "hessian" /
                "model" / "hessian" / "part_1"
            )
            part_dir.mkdir(parents=True)
            (part_dir / "part.hes").write_bytes(b"native-hessian-part")
            subprocess.run(
                [
                    "Rscript", "-e",
                    "saveRDS(list(run_status='completed', output_hessian='part.hes', "
                    "hessian_part=1L), commandArgs(TRUE)[1])",
                    str(part_dir / "hessian_info.rds"),
                ],
                check=True,
                text=True,
                capture_output=True,
            )

            env = {
                **os.environ,
                "MODEL_INPUT_ROOT": str(input_root),
                "OUTPUT_DIR": str(output_dir),
                "MODEL_SELECTOR": "model",
                "MODEL_BASE_INPUT_JOB": "3001",
                "MODEL_ORIGINAL_BASE_INPUT_JOB": "3001",
                "HESSIAN_NSPLIT": "1",
                "CHECK_SMOKE_ONLY": "true",
                "CHECK_COMPACT_OUTPUTS": "true",
                "CHECK_ENRICH_PAYLOADS": "false",
                "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
                "ATTACH_OUTPUT_MODE": "delta",
            }
            subprocess.run(
                ["Rscript", "R/merge_hessian.R"],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=True,
            )

            published = output_dir / "models" / "model"
            self.assertFalse((output_dir / "checks").exists())
            self.assertEqual((published / "model_payload.rds").read_bytes(), payload_bytes)
            self.assertTrue((published / "hessian" / "hessian_info.rds").is_file())
            self.assertFalse((published / "retro").exists())
            self.assertFalse((published / "base-only.frq").exists())
            with (published / "attached-checks-index.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                retained = {row["check_type"] for row in csv.DictReader(handle)}
            self.assertEqual(retained, {"hessian"})
            with (output_dir / "attached-model-bundle.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                bundle = next(csv.DictReader(handle))
            self.assertEqual(bundle["output_mode"], "delta")
            self.assertEqual(bundle["overlay_payload_mode"], "diagnostics_with_payload")
            self.assertIn("3001", bundle["overlay_base_input_job"])

    def test_direct_delta_keeps_failed_hessian_part_ledger(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            output_dir = root / "outputs"
            base_model = input_root / "3001" / "outputs" / "models" / "model"
            base_model.mkdir(parents=True)
            (base_model / "model_payload.rds").write_bytes(b"base-payload")
            (base_model / "model_payload_manifest.json").write_text("{}\n", encoding="utf-8")
            with (base_model / "model_payload_manifest.csv").open(
                "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(handle, fieldnames=["role", "file"])
                writer.writeheader()
                writer.writerow({"role": "model_payload", "file": "model_payload.rds"})
            (base_model / "model.frq").write_text("base input\n", encoding="utf-8")
            with (input_root / "3001" / "outputs" / "model-index.csv").open(
                "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["model_key", "model_label", "step_id", "model_dir", "model_folder"],
                )
                writer.writeheader()
                writer.writerow({
                    "model_key": "model",
                    "model_label": "model",
                    "step_id": "model",
                    "model_dir": "models/model",
                    "model_folder": "model",
                })

            subprocess.run(
                ["Rscript", "R/merge_hessian.R"],
                cwd=ROOT,
                env={
                    **os.environ,
                    "MODEL_INPUT_ROOT": str(input_root),
                    "OUTPUT_DIR": str(output_dir),
                    "MODEL_SELECTOR": "model",
                    "MODEL_BASE_INPUT_JOB": "3001",
                    "MODEL_ORIGINAL_BASE_INPUT_JOB": "3001",
                    "CHECK_INPUT_JOBS": "missing-part-jobs",
                    "HESSIAN_NSPLIT": "2",
                    "CHECK_SMOKE_ONLY": "true",
                    "CHECK_COMPACT_OUTPUTS": "true",
                    "CHECK_ENRICH_PAYLOADS": "false",
                    "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
                    "ATTACH_OUTPUT_MODE": "delta",
                },
                text=True,
                capture_output=True,
                check=True,
            )

            published = output_dir / "models" / "model"
            self.assertFalse((output_dir / "checks").exists())
            self.assertTrue((published / "hessian" / "hessian_info.rds").is_file())
            self.assertFalse((published / "model.frq").exists())
            with (published / "hessian" / "check-unit-status.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual([row["part"] for row in rows], ["1", "2"])
            self.assertTrue(all(row["run_status"] == "missing" for row in rows))
            with (published / "attached-checks-index.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                retained = {row["check_type"] for row in csv.DictReader(handle)}
            self.assertEqual(retained, {"hessian"})

    def test_compact_base_stitches_from_explicit_current_unit_prerequisites(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root = root / "inputs"
            output_dir = root / "outputs"
            base_model = input_root / "3001" / "outputs" / "models" / "model"
            base_model.mkdir(parents=True)
            subprocess.run(
                [
                    "Rscript", "-e",
                    "saveRDS(list(data=list(info=list(source='compact-base'))), commandArgs(TRUE)[1])",
                    str(base_model / "model_payload.rds"),
                ],
                check=True,
                text=True,
                capture_output=True,
            )
            (base_model / "model_payload_manifest.json").write_text("{}\n", encoding="utf-8")
            with (base_model / "model_payload_manifest.csv").open(
                "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(handle, fieldnames=["role", "file"])
                writer.writeheader()
                writer.writerow({"role": "model_payload", "file": "model_payload.rds"})
            with (input_root / "3001" / "outputs" / "model-index.csv").open(
                "w", newline="", encoding="utf-8"
            ) as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=["model_key", "model_label", "step_id", "model_dir", "model_folder"],
                )
                writer.writeheader()
                writer.writerow({
                    "model_key": "model",
                    "model_label": "model",
                    "step_id": "model",
                    "model_dir": "models/model",
                    "model_folder": "model",
                })

            unit_model = (
                input_root / "3287" / "outputs" / "checks" / "hessian" / "model"
            )
            part_dir = unit_model / "hessian" / "part_1"
            part_dir.mkdir(parents=True)
            (unit_model / "model.frq").write_text("current unit frq\n", encoding="utf-8")
            (unit_model / "final.par").write_text("current unit par\n", encoding="utf-8")
            # One-parameter partial Hessian header plus one double value.
            (part_dir / "part.hes").write_bytes(
                struct.pack("<iii", 1, 1, 1) + struct.pack("<d", 1.0)
            )
            subprocess.run(
                [
                    "Rscript", "-e",
                    (
                        "saveRDS(list(run_status='completed', output_hessian='part.hes', "
                        "hessian_part=1L, nsplit=1L, npars=1L, start_par=1L, end_par=1L, "
                        "frq_file='model.frq', input_par='final.par', "
                        "input_dir='/unavailable/previous-job/work', program_path=''), "
                        "commandArgs(TRUE)[1])"
                    ),
                    str(part_dir / "hessian_info.rds"),
                ],
                check=True,
                text=True,
                capture_output=True,
            )

            subprocess.run(
                ["Rscript", "R/merge_hessian.R"],
                cwd=ROOT,
                env={
                    **os.environ,
                    "MODEL_INPUT_ROOT": str(input_root),
                    "OUTPUT_DIR": str(output_dir),
                    "MODEL_SELECTOR": "model",
                    "MODEL_BASE_INPUT_JOB": "3001",
                    "MODEL_ORIGINAL_BASE_INPUT_JOB": "3001",
                    "CHECK_INPUT_JOBS": "3287",
                    "ATTACH_CHECK_TYPES": "hessian",
                    "HESSIAN_NSPLIT": "1",
                    # run=FALSE still exercises native stitch preparation.
                    "HESSIAN_MERGE_RUN": "false",
                    "HESSIAN_MERGE_EIGEN": "false",
                    "CHECK_COMPACT_OUTPUTS": "true",
                    "CHECK_ENRICH_PAYLOADS": "false",
                    "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
                    "ATTACH_OUTPUT_MODE": "delta",
                },
                text=True,
                capture_output=True,
                check=True,
            )

            published = output_dir / "models" / "model"
            with (published / "hessian" / "check-summary.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                summary = next(csv.DictReader(handle))
            self.assertEqual(summary["merge_status"], "complete")
            with (published / "hessian" / "check_manifest.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                manifest = next(csv.DictReader(handle))
            self.assertEqual(manifest["base_input_job"], "3001")
            self.assertEqual(manifest["original_base_input_job"], "3001")
            self.assertEqual(manifest["check_input_jobs"], "3287")
            self.assertIn("3287", manifest["stitch_input_source_dirs"])
            self.assertIn("model.frq", manifest["staged_stitch_inputs"])
            self.assertIn("final.par", manifest["staged_stitch_inputs"])
            # Delta publication still removes raw stitch inputs.
            self.assertFalse((published / "model.frq").exists())
            self.assertFalse((published / "final.par").exists())

    def test_hessian_merge_rejects_non_hessian_attach_type(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            process = subprocess.run(
                ["Rscript", "R/merge_hessian.R"],
                cwd=ROOT,
                env={
                    **os.environ,
                    "MODEL_INPUT_ROOT": tmpdir,
                    "OUTPUT_DIR": str(Path(tmpdir) / "outputs"),
                    "MODEL_SELECTOR": "model",
                    "ATTACH_CHECK_TYPES": "jitter",
                    "CHECK_ENRICH_PAYLOADS": "false",
                },
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("only the current merge type 'hessian'", process.stderr)


if __name__ == "__main__":
    unittest.main()
