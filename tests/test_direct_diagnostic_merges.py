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
class DirectDiagnosticMergeTests(unittest.TestCase):
    updated_paths = {
        "jitter": Path("jitter/jitter_seed_1/current-result.txt"),
        "retro": Path("retro/peel_1/current-result.txt"),
        "profile": Path("profile/adult_biomass/scalar_90/current-result.txt"),
        "aspm": Path("aspm/current-result.txt"),
        "selftest": Path("selftest/sim/rep_1/current-result.txt"),
    }

    def make_case(self, root: Path, check_type: str) -> tuple[Path, Path, Path]:
        input_root = root / "inputs"
        output_dir = root / "outputs"
        base_model = input_root / "3001" / "outputs" / "models" / "model"
        base_model.mkdir(parents=True)

        subprocess.run(
            [
                "Rscript",
                "-e",
                "saveRDS(list(data=list(info=list(source='base'))), commandArgs(TRUE)[1])",
                str(base_model / "model_payload.rds"),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        (base_model / "model_payload_manifest.json").write_text("{}\n", encoding="utf-8")
        write_csv(
            base_model / "model_payload_manifest.csv",
            [{"role": "model_payload", "file": "model_payload.rds"}],
        )
        for name in ("model.frq", "model.ini", "final.par", "plot.rep"):
            (base_model / name).write_text(f"base {name}\n", encoding="utf-8")

        stale_current = base_model / check_type / "stale-current.txt"
        stale_current.parent.mkdir(parents=True, exist_ok=True)
        stale_current.write_text("must be replaced\n", encoding="utf-8")
        write_csv(
            input_root / "3001" / "outputs" / "model-index.csv",
            [{
                "model_key": "model",
                "model_label": "Base model label",
                "step_id": "model",
                "model_dir": "models/model",
                "model_folder": "model",
                "payload_role": "model_root",
            }],
        )

        unit_model = (
            input_root / "4001" / "outputs" / "checks" / check_type / "model"
        )
        current_result = unit_model / self.updated_paths[check_type]
        current_result.parent.mkdir(parents=True)
        current_result.write_text(f"current {check_type}\n", encoding="utf-8")
        subprocess.run(
            [
                "Rscript",
                "-e",
                "saveRDS(list(check_type=commandArgs(TRUE)[1]), commandArgs(TRUE)[2])",
                check_type,
                str(unit_model / "check_manifest.rds"),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        write_csv(
            unit_model / "check_manifest.csv",
            [{"check_type": check_type, "model_key": "model"}],
        )
        write_csv(
            unit_model / "check-summary.csv",
            [{
                "check_type": check_type,
                "run_status": "completed",
                "success": "TRUE",
            }],
        )
        write_csv(
            input_root / "4001" / "outputs" / "checks" / check_type / "model-index.csv",
            [{
                "check_type": check_type,
                "model_key": "model",
                "model_label": "model",
                "step_id": "model",
                "model_dir": "model",
                "model_folder": "model",
                "payload_role": "check_model_root",
            }],
        )
        return input_root, output_dir, base_model

    def run_merge(
        self,
        input_root: Path,
        output_dir: Path,
        check_type: str,
        output_mode: str = "delta",
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "MODEL_INPUT_ROOT": str(input_root),
            "OUTPUT_DIR": str(output_dir),
            "MODEL_SELECTOR": "model",
            "MODEL_BASE_INPUT_JOB": "3001",
            "BASE_MODEL_JOB": "3001",
            "MODEL_ORIGINAL_BASE_INPUT_JOB": "3001",
            "CHECK_TYPE": f"{check_type}-merge",
            "CHECK_MERGE_TYPE": check_type,
            "CHECK_INPUT_JOBS": "4001",
            "ATTACH_CHECK_TYPES": check_type,
            "CHECK_SMOKE_ONLY": "true",
            "CHECK_REQUIRE_MFCLKIT": "false",
            "CHECK_ENRICH_PAYLOADS": "false",
            "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
            "CHECK_COMPACT_OUTPUTS": "false",
            "CHECK_BUILD_REPORT_FIGURES": "false",
            "ATTACH_OUTPUT_MODE": output_mode,
            **(extra_env or {}),
        }
        if check_type == "profile":
            env.update({
                "PROFILE_INCLUDE_BASE_ANCHOR": "false",
                "PROFILE_EXPECTED_VALUES": "90",
            })
        return subprocess.run(
            ["Rscript", "R/merge_check.R"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )

    def test_each_merge_job_can_publish_its_own_independent_delta(self):
        for check_type in self.updated_paths:
            with self.subTest(check_type=check_type), tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                input_root, output_dir, _ = self.make_case(root, check_type)
                self.run_merge(input_root, output_dir, check_type)

                published = output_dir / "models" / "model"
                self.assertFalse((output_dir / "checks").exists())
                self.assertTrue((published / "model_payload.rds").is_file())
                self.assertTrue((published / self.updated_paths[check_type]).is_file())
                self.assertFalse((published / check_type / "stale-current.txt").exists())
                sibling_types = set(self.updated_paths) - {check_type}
                sibling_types.add("hessian")
                for sibling in sibling_types:
                    self.assertFalse((published / sibling).exists(), sibling)
                for name in ("model.frq", "model.ini", "final.par", "plot.rep"):
                    self.assertFalse((published / name).exists(), name)

                retained = {
                    row["check_type"]
                    for row in read_csv(published / "attached-checks-index.csv")
                }
                self.assertEqual(retained, {check_type})
                self.assertTrue((published / check_type / "check-summary.csv").is_file())
                bundle = read_csv(output_dir / "attached-model-bundle.csv")[0]
                self.assertEqual(bundle["output_mode"], "delta")
                self.assertEqual(bundle["overlay_base_input_job"], "3001")
                index = read_csv(output_dir / "model-index.csv")[0]
                self.assertEqual(index["model_label"], "Base model label")
                subprocess.run(
                    [
                        "Rscript",
                        "-e",
                        (
                            "p <- readRDS(commandArgs(TRUE)[1]); "
                            "x <- if (is.list(p$data)) p$data else p; "
                            "expected <- commandArgs(TRUE)[2]; "
                            "stopifnot(identical(x$info$attached_checks$check_types, expected)); "
                            "stopifnot(is.data.frame(x$info$attached_checks$status[[expected]]))"
                        ),
                        str(published / "model_payload.rds"),
                        check_type,
                    ],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    check=True,
                )
                payload_manifest = read_csv(
                    published / "model_payload_manifest.csv"
                )[0]
                self.assertEqual(
                    int(float(payload_manifest["payload_bytes"])),
                    (published / "model_payload.rds").stat().st_size,
                )

    def test_full_mode_preserves_a_standalone_case(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, _ = self.make_case(root, "jitter")
            self.run_merge(input_root, output_dir, "jitter", output_mode="full")

            published = output_dir / "models" / "model"
            for name in ("model.frq", "model.ini", "final.par", "plot.rep"):
                self.assertTrue((published / name).is_file(), name)
            self.assertTrue((published / self.updated_paths["jitter"]).is_file())
            bundle = read_csv(output_dir / "attached-model-bundle.csv")[0]
            self.assertEqual(bundle["output_mode"], "full")
            self.assertEqual(bundle["overlay_base_required"], "FALSE")

    def test_missing_current_unit_attaches_failure_ledger_without_stale_result(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, _ = self.make_case(root, "jitter")
            shutil.rmtree(input_root / "4001")
            self.run_merge(
                input_root,
                output_dir,
                "jitter",
                extra_env={
                    "CHECK_EXPECTED_UNIT_TYPE": "seed",
                    "CHECK_EXPECTED_UNITS": "1",
                },
            )

            published = output_dir / "models" / "model"
            self.assertFalse((published / "jitter" / "stale-current.txt").exists())
            status = read_csv(published / "jitter" / "check-unit-status.csv")
            self.assertEqual([row["check_unit"] for row in status], ["1"])
            self.assertEqual([row["run_status"] for row in status], ["missing"])
            subprocess.run(
                [
                    "Rscript",
                    "-e",
                    (
                        "p <- readRDS(commandArgs(TRUE)[1]); "
                        "x <- if (is.list(p$data)) p$data else p; "
                        "stopifnot(identical(x$info$attached_checks$check_types, 'jitter')); "
                        "stopifnot(is.data.frame(x$Diagnostics$jitter)); "
                        "stopifnot(any(tolower(as.character(x$Diagnostics$jitter$run_status)) == 'missing')); "
                        "stopifnot(is.data.frame(x$info$attached_checks$status$jitter))"
                    ),
                    str(published / "model_payload.rds"),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            )

    def test_each_missing_diagnostic_job_publishes_visible_failure_status(self):
        for check_type in self.updated_paths:
            with self.subTest(check_type=check_type), tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                input_root, output_dir, _ = self.make_case(root, check_type)
                shutil.rmtree(input_root / "4001")
                self.run_merge(input_root, output_dir, check_type)

                published = output_dir / "models" / "model"
                status = read_csv(published / check_type / "check-unit-status.csv")
                self.assertTrue(all(row["run_status"].startswith("missing") for row in status))
                self.assertEqual([row["success"] for row in status], ["FALSE"])
                retained = {
                    row["check_type"]
                    for row in read_csv(published / "attached-checks-index.csv")
                }
                self.assertEqual(retained, {check_type})
                subprocess.run(
                    [
                        "Rscript",
                        "-e",
                        (
                            "p <- readRDS(commandArgs(TRUE)[1]); "
                            "x <- if (is.list(p$data)) p$data else p; "
                            "kind <- commandArgs(TRUE)[2]; "
                            "d <- x$Diagnostics[[kind]]; "
                            "stopifnot(is.data.frame(d)); "
                            "stopifnot(any(startsWith(tolower(as.character(d$run_status)), 'missing'))); "
                            "stopifnot(is.data.frame(x$info$attached_checks$status[[kind]]))"
                        ),
                        str(published / "model_payload.rds"),
                        check_type,
                    ],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    check=True,
                )

    def test_failure_ledger_replaces_same_unit_collector_row_and_flags_summaries(self):
        expression = r'''
source("R/model_output_adapter.R")
existing <- data.frame(
  check_unit = "1",
  run_status = "completed",
  success = TRUE,
  value = 99,
  stringsAsFactors = FALSE
)
ledger <- data.frame(
  check_unit = "1",
  run_status = "missing",
  success = FALSE,
  failure_reason = "current unit missing",
  stringsAsFactors = FALSE
)
merged <- merge_diagnostic_status_rows(existing, ledger)
stopifnot(nrow(merged) == 1L)
stopifnot(identical(as.character(merged$run_status), "missing"))
stopifnot(identical(as.logical(merged$success), FALSE))
stopifnot(identical(as.character(merged$failure_reason), "current unit missing"))

summary <- data.frame(
  merge_status = c("no_units", "complete", "complete"),
  has_failures = c(FALSE, TRUE, FALSE),
  all_required_units_successful = c(TRUE, TRUE, FALSE),
  stringsAsFactors = FALSE
)
failed <- diagnostic_failure_rows(summary)
stopifnot(identical(as.integer(rownames(failed)), c(1L, 2L, 3L)))
'''
        subprocess.run(
            ["Rscript", "-e", expression],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
