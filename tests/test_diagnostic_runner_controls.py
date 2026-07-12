from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DiagnosticRunnerControlTests(unittest.TestCase):
    def test_jitter_requirement_reaches_both_runner_paths(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        task = (ROOT / "jitter" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn(
            'jitter_require_indepvar <- truthy(env("JITTER_REQUIRE_INDEPVAR", "true"), TRUE)',
            runner,
        )
        self.assertIn("require_indepvar = jitter_require_indepvar", runner)
        self.assertIn('JITTER_REQUIRE_INDEPVAR: "true"', task)

    def test_phase1_jitter_infers_model_specific_par_names(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")

        self.assertIn('env("JITTER_MAKEPAR_PAR", "")', runner)
        self.assertIn('env("JITTER_PHASE1_PAR", "")', runner)
        self.assertNotIn('env("JITTER_MAKEPAR_PAR", "00.par")', runner)
        self.assertNotIn('env("JITTER_PHASE1_PAR", "01.par")', runner)

    def test_direct_retro_resolves_auto_to_a_real_warm_start_name(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")

        self.assertIn(
            'if (isTRUE(retro_use_doitall)) "auto" else "retro-start.par"',
            runner,
        )
        self.assertIn(
            'start_strategy = if (isTRUE(retro_use_doitall)) "fresh_makepar" else "fitted_warm_start"',
            runner,
        )

    def test_hessian_units_preserve_regional_scaling_for_later_stitching(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        start = runner.index("stage_hessian_stitch_inputs <- function()")
        end = runner.index("write_check_payload_index <- function", start)

        self.assertIn('"[.]reg_scaling$"', runner[start:end])


if __name__ == "__main__":
    unittest.main()
