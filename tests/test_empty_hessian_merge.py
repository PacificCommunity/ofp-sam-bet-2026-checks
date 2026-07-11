import csv
import os
import shutil
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


if __name__ == "__main__":
    unittest.main()
