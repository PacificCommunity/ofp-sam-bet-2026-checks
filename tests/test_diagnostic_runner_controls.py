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

    def test_jitter_default_cv_is_point_one(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        task = (ROOT / "jitter" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn('JITTER_CV: "0.1"', task)
        self.assertIn('env("JITTER_CV", "0.1")', runner)
        self.assertIn("default = 0.1", runner)

    def test_direct_retro_resolves_auto_to_a_real_warm_start_name(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")

        self.assertIn(
            'if (isTRUE(retro_use_doitall)) "" else "retro-start.par"',
            runner,
        )
        self.assertIn('start_strategy = retro_start_strategy', runner)

    def test_retro_auto_preserves_model_script_start_semantics(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")

        self.assertIn('env("RETRO_START_STRATEGY", "auto")', runner)
        self.assertIn('"auto", "model_phase_start", "fresh_makepar", "fitted_warm_start"', runner)
        self.assertNotIn(
            'start_strategy = if (isTRUE(retro_use_doitall)) "fresh_makepar"',
            runner,
        )

    def test_retro_defaults_to_full_doitall_and_fails_if_it_is_missing(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        task = (ROOT / "retro" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn('RETRO_USE_DOITALL: "true"', task)
        self.assertIn('env("RETRO_USE_DOITALL", "true")', runner)
        self.assertIn(
            "if (isTRUE(retro_use_doitall) && !isTRUE(retro_has_doitall))",
            runner,
        )
        self.assertIn(
            '"RETRO_USE_DOITALL=true requires a staged doitall.sh. "',
            runner,
        )

    def test_selftest_uses_fitted_truth_then_refits_the_full_doitall(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        task = (ROOT / "selftest" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn("SELFTEST_SOURCE_MODE: last_par", task)
        self.assertIn("SELFTEST_REFIT_MODE: doitall", task)
        self.assertIn('env("SELFTEST_SOURCE_MODE", "last_par")', runner)
        self.assertIn('env("SELFTEST_REFIT_MODE", "doitall")', runner)
        self.assertIn("par = check_start_par", runner)

    def test_selftest_failed_units_fail_the_unit_task_by_default(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        launcher = (ROOT / "run.sh").read_text(encoding="utf-8")
        task = (ROOT / "selftest" / "kflow.yaml").read_text(encoding="utf-8")
        merge_task = (ROOT / "selftest-merge" / "kflow.yaml").read_text(
            encoding="utf-8"
        )

        self.assertIn('CHECK_FAIL_ON_FAILED_UNITS: "true"', task)
        self.assertIn(
            'fail_on_failed_units_default <- identical(check_type, "selftest")',
            runner,
        )
        self.assertIn("(is.finite(n_failed) && n_failed > 0L)", runner)
        self.assertIn("set -euo pipefail", launcher)
        self.assertIn('Rscript R/run_check.R "$CHECK_TYPE"', launcher)
        self.assertNotIn("CHECK_FAIL_ON_FAILED_UNITS:", merge_task)

        for check_type in ("jitter", "retro", "profile", "aspm", "hessian"):
            unit_task = (ROOT / check_type / "kflow.yaml").read_text(
                encoding="utf-8"
            )
            self.assertIn('CHECK_FAIL_ON_FAILED_UNITS: "false"', unit_task)

    def test_selftest_completion_is_not_the_same_as_convergence(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")

        self.assertIn('if (identical(check_type, "selftest")) {', runner)
        self.assertIn('c("run_status", "status")', runner)
        self.assertIn(
            '!identical(check_type, "selftest") && "converged" %in% names(dat)',
            runner,
        )

    def test_aspm_and_profile_start_from_the_fitted_final_par(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        profile_start = runner.rindex('\n} else if (identical(check_type, "profile"))')
        aspm_start = runner.rindex('\n} else if (identical(check_type, "aspm"))')
        selftest_start = runner.rindex('\n} else if (identical(check_type, "selftest"))')

        self.assertIn("par = check_start_par", runner[profile_start:aspm_start])
        self.assertIn(
            "attempts <- list(run_aspm(check_start_par))",
            runner[aspm_start:selftest_start],
        )

    def test_profile_full_doitall_is_an_explicit_mfclkit_dispatch(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        task = (ROOT / "profile" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn('env("PROFILE_EXECUTION_MODE", "continuation")', runner)
        self.assertIn('profile_args$execution <- profile_execution_mode', runner)
        self.assertIn('profile_args$doitall <- profile_doitall_script', runner)
        self.assertIn('profile_args$doitall_penalty <- profile_doitall_penalty', runner)
        self.assertIn('profile_args$parallel_points <- FALSE', runner)
        self.assertIn("PROFILE_EXECUTION_MODE: continuation", task)
        self.assertIn('PROFILE_DOITALL_PENALTY: "10000000"', task)

    def test_profile_keeps_only_the_restart_par_needed_by_merge_repair(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")

        self.assertIn(
            'truthy(env("PROFILE_POST_MERGE_REPAIR", "true"), TRUE)',
            runner,
        )
        self.assertIn('"profile.par"', runner)

    def test_aspm_defaults_to_the_strict_constant_recruitment_definition(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        task = (ROOT / "aspm" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn('env("ASPM_RECRUITMENT_MODE", "constant")', runner)
        self.assertIn('env("ASPM_DIAGNOSTIC_DEFINITION", "strict")', runner)
        self.assertIn("recruitment_mode = recruitment_mode", runner)
        self.assertIn("diagnostic_definition = diagnostic_definition", runner)
        self.assertIn("ASPM_RECRUITMENT_MODE: constant", task)
        self.assertIn("ASPM_DIAGNOSTIC_DEFINITION: strict", task)

    def test_hessian_units_preserve_regional_scaling_for_later_stitching(self) -> None:
        runner = (ROOT / "R" / "run_check.R").read_text(encoding="utf-8")
        start = runner.index("stage_hessian_stitch_inputs <- function()")
        end = runner.index("write_check_payload_index <- function", start)

        self.assertIn('"[.]reg_scaling$"', runner[start:end])


if __name__ == "__main__":
    unittest.main()
