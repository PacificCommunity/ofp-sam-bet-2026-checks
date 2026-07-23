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


if __name__ == "__main__":
    unittest.main()
