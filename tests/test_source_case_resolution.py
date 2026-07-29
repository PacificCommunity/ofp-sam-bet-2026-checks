import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "R" / "model_output_adapter.R"


class SourceCaseResolutionTests(unittest.TestCase):
    def test_broad_source_path_resolves_selected_model_case(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            source_root = Path(tmpdir) / "source"
            model_name = "S009-example"
            model_dir = source_root / "sensitivity" / model_name / "model"
            model_dir.mkdir(parents=True)
            (model_dir / "bet.frq").write_text("example\n", encoding="utf-8")

            expression = (
                f"source({str(ADAPTER)!r}); "
                f"Sys.setenv(MODEL_SOURCE_PATH='sensitivity', MODEL_SELECTOR={model_name!r}); "
                "row <- list(model_source='sensitivity', model_key='model-key', step_id=''); "
                f"resolved <- resolve_source_case(row, {str(source_root)!r}); "
                f"stopifnot(identical(normalize_loose(resolved), normalize_loose({str(model_dir)!r})))"
            )
            subprocess.run(
                ["Rscript", "-e", expression],
                cwd=ROOT,
                check=True,
                text=True,
                capture_output=True,
            )

    def test_indexed_complete_case_keeps_native_fitted_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            model_dir = root / "outputs" / "models" / "F14-Y5-REC01"
            model_dir.mkdir(parents=True)
            (model_dir / "bet.frq").write_text("example\n", encoding="utf-8")
            (model_dir / "bet.ini").write_text("example\n", encoding="utf-8")
            (model_dir / "final.par").write_text(
                "# Objective function value\n1\n"
                "# The number of parameters\n1\n",
                encoding="utf-8",
            )
            (model_dir / "plot-final.par.rep").write_text(
                "native fitted report\n", encoding="utf-8"
            )
            nested = model_dir / "mfcl-inputs"
            nested.mkdir()
            (nested / "bet.frq").write_text("input only\n", encoding="utf-8")
            (nested / "bet.ini").write_text("input only\n", encoding="utf-8")

            work_dir = root / "work"
            output_dir = root / "check-output"
            expression = (
                f"source({str(ADAPTER)!r}); "
                "row <- data.frame("
                "candidate_type='indexed', model_key='F14-Y5-REC01', "
                f"compact_dir={str(model_dir)!r}, final_par='final.par', "
                "stringsAsFactors=FALSE); "
                f"staged <- stage_selected_model(row, work_dir={str(work_dir)!r}, "
                f"output_dir={str(output_dir)!r}); "
                "stopifnot(file.exists(file.path(staged$case_dir, "
                "'plot-final.par.rep')))"
            )
            subprocess.run(
                ["Rscript", "-e", expression],
                cwd=ROOT,
                check=True,
                text=True,
                capture_output=True,
            )


if __name__ == "__main__":
    unittest.main()
