import importlib.util
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "submit_kflow_checks",
    ROOT / "scripts" / "submit_kflow_checks.py",
)
assert SPEC is not None and SPEC.loader is not None
submit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(submit)


def decode_dry_run_payloads(output: str) -> list[dict]:
    decoder = json.JSONDecoder()
    payloads = []
    remaining = output.lstrip()
    while remaining:
        value, end = decoder.raw_decode(remaining)
        payloads.append(value)
        remaining = remaining[end:].lstrip()
    return payloads


def run_dry_run(argv: list[str], env: dict[str, str] | None = None) -> list[dict]:
    output = io.StringIO()
    with (
        mock.patch.dict(os.environ, env or {}, clear=True),
        mock.patch.object(sys, "argv", argv),
        redirect_stdout(output),
    ):
        if submit.main() != 0:
            raise AssertionError("dry-run submission failed")
    return decode_dry_run_payloads(output.getvalue())


class IntegerUnitSpecTests(unittest.TestCase):
    CASES = (
        ("jitter", "JITTER_SEEDS", "JITTER_SEED", "seed"),
        ("retro", "RETRO_PEELS", "RETRO_PEEL", "peel"),
        ("selftest", "SELFTEST_REPS", "SELFTEST_REP", "replicate"),
    )

    def test_parallel_and_batched_specs_share_one_canonical_ledger(self):
        canonical = ["1", "2", str(submit.MAX_R_INTEGER)]
        raw = f"+001, 2 1 {submit.MAX_R_INTEGER} 02"

        for check, plural, singular, unit_type in self.CASES:
            with self.subTest(check=check), mock.patch.dict(os.environ, {plural: raw}, clear=True):
                parallel = submit.check_unit_specs(check, parallel_units=True)
                batched = submit.check_unit_specs(check, parallel_units=False)

            self.assertEqual(
                [spec["metadata"]["check_unit"] for spec in parallel],
                canonical,
            )
            self.assertEqual(
                [spec["env"][plural] for spec in parallel],
                canonical,
            )
            self.assertEqual(
                [spec["env"][singular] for spec in parallel],
                canonical,
            )
            self.assertEqual(len(batched), 1)
            self.assertEqual(batched[0]["env"][plural], " ".join(canonical))
            self.assertEqual(batched[0]["env"][singular], "")
            self.assertEqual(batched[0]["metadata"]["check_units"], canonical)
            self.assertEqual(batched[0]["metadata"]["check_unit_type"], unit_type)
            self.assertEqual(submit.expected_unit_ledger(parallel), (unit_type, canonical))
            self.assertEqual(submit.expected_unit_ledger(batched), (unit_type, canonical))

    def test_singular_fallback_is_canonicalized(self):
        for check, plural, singular, unit_type in self.CASES:
            with self.subTest(check=check), mock.patch.dict(os.environ, {singular: "+0007"}, clear=True):
                specs = submit.check_unit_specs(check, parallel_units=False)
            self.assertEqual(specs[0]["env"][plural], "7")
            self.assertEqual(submit.expected_unit_ledger(specs), (unit_type, ["7"]))

    def test_invalid_or_empty_integer_unit_lists_fail_explicitly(self):
        invalid_values = ("0", "-1", "1.5", "one", str(submit.MAX_R_INTEGER + 1), ",,,")
        for check, plural, _singular, _unit_type in self.CASES:
            for value in invalid_values:
                with self.subTest(check=check, value=value), mock.patch.dict(
                    os.environ,
                    {plural: value},
                    clear=True,
                ):
                    with self.assertRaises(SystemExit):
                        submit.check_unit_specs(check, parallel_units=True)

    def test_batched_dry_run_forwards_the_canonical_ledger_to_merge(self):
        argv = [
            "submit_kflow_checks.py",
            "--checks", "jitter",
            "--models", "model",
            "--parallel-units", "false",
            "--auto-attach", "false",
            "--dry-run",
        ]
        output = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"JITTER_SEEDS": "+01 2 1 02"}, clear=True),
            mock.patch.object(sys, "argv", argv),
            redirect_stdout(output),
        ):
            self.assertEqual(submit.main(), 0)

        decoder = json.JSONDecoder()
        payloads = []
        remaining = output.getvalue().lstrip()
        while remaining:
            value, end = decoder.raw_decode(remaining)
            payloads.append(value)
            remaining = remaining[end:].lstrip()
        self.assertEqual([item["task"] for item in payloads], [
            "ofp-sam-bet-2026-check-jitter",
            "ofp-sam-bet-2026-check-jitter-merge",
        ])
        unit_payload = payloads[0]["payload"]
        self.assertEqual(unit_payload["env"]["JITTER_SEEDS"], "1 2")
        self.assertNotIn("JITTER_SEED", unit_payload["env"])
        self.assertEqual(unit_payload["metadata"]["check_units"], ["1", "2"])
        merge_payload = payloads[1]["payload"]
        self.assertEqual(merge_payload["env"]["CHECK_EXPECTED_UNIT_TYPE"], "seed")
        self.assertEqual(merge_payload["env"]["CHECK_EXPECTED_UNITS"], "1 2")
        self.assertEqual(merge_payload["metadata"]["check_expected_units"], ["1", "2"])

    def test_species_metadata_reaches_unit_and_direct_merge_jobs(self):
        argv = [
            "submit_kflow_checks.py",
            "--checks", "jitter",
            "--models", "model",
            "--input-jobs", "123",
            "--parallel-units", "false",
            "--dry-run",
        ]
        metadata = {
            "JITTER_SEEDS": "1",
            "FLOW_SPECIES": "YFT",
            "FLOW_SPECIES_LABEL": "yellowfin tuna",
            "FLOW_ASSESSMENT_YEAR": "2027",
        }
        output = io.StringIO()
        with (
            mock.patch.dict(os.environ, metadata, clear=True),
            mock.patch.object(sys, "argv", argv),
            redirect_stdout(output),
        ):
            self.assertEqual(submit.main(), 0)

        decoder = json.JSONDecoder()
        payloads = []
        remaining = output.getvalue().lstrip()
        while remaining:
            value, end = decoder.raw_decode(remaining)
            payloads.append(value)
            remaining = remaining[end:].lstrip()

        self.assertEqual(len(payloads), 2)
        for item in payloads:
            env = item["payload"]["env"]
            self.assertEqual(env["FLOW_SPECIES"], "YFT")
            self.assertEqual(env["FLOW_SPECIES_LABEL"], "yellowfin tuna")
            self.assertEqual(env["FLOW_ASSESSMENT_YEAR"], "2027")

    def test_selftest_units_fail_on_failed_replicates_by_default(self):
        argv = [
            "submit_kflow_checks.py",
            "--checks", "selftest",
            "--models", "model",
            "--input-jobs", "123",
            "--parallel-units", "false",
            "--dry-run",
        ]
        payloads = run_dry_run(argv, {"SELFTEST_REPS": "1"})

        self.assertEqual(len(payloads), 2)
        unit = payloads[0]["payload"]
        merge = payloads[1]["payload"]
        self.assertEqual(unit["env"]["CHECK_FAIL_ON_FAILED_UNITS"], "true")
        self.assertNotIn("CHECK_FAIL_ON_FAILED_UNITS", merge["env"])

        overridden = run_dry_run(
            argv,
            {
                "SELFTEST_REPS": "1",
                "CHECK_FAIL_ON_FAILED_UNITS": "false",
            },
        )
        self.assertEqual(
            overridden[0]["payload"]["env"]["CHECK_FAIL_ON_FAILED_UNITS"],
            "false",
        )

    def test_scalar_mode_emits_one_non_center_job_per_value_and_one_merge(self):
        values = "80 90 110 120"
        expected_values = "80 90 100 110 120"
        payloads = run_dry_run(
            [
                "submit_kflow_checks.py",
                "--checks", "profile",
                "--models", "model",
                "--input-jobs", "3001",
                "--parallel-units", "true",
                "--auto-attach", "false",
                "--dry-run",
            ],
            {
                "PROFILE_PARALLEL_MODE": "scalars",
                "PROFILE_EXECUTION_MODE": "doitall",
                "PROFILE_VALUES": values,
                "PROFILE_CENTER": "100",
            },
        )

        self.assertEqual(len(payloads), 5)
        units, merge = payloads[:-1], payloads[-1]
        self.assertTrue(all(item["task"].endswith("-profile") for item in units))
        self.assertTrue(merge["task"].endswith("-profile-merge"))
        self.assertEqual(
            [item["payload"]["metadata"]["check_unit"] for item in units],
            ["80", "90", "110", "120"],
        )
        self.assertNotIn(
            "100",
            [item["payload"]["metadata"]["check_unit"] for item in units],
        )

        for item, side in zip(units, ["downstream", "downstream", "upstream", "upstream"]):
            payload = item["payload"]
            env = payload["env"]
            metadata = payload["metadata"]
            self.assertEqual(env["PROFILE_PARALLEL_MODE"], "scalars")
            self.assertEqual(env["PROFILE_EXECUTION_MODE"], "doitall")
            self.assertEqual(env["PROFILE_CHAIN"], "false")
            self.assertEqual(env["PROFILE_CHAIN_SIDE"], side)
            self.assertEqual(env["PROFILE_INCLUDE_BASE_ANCHOR"], "false")
            self.assertEqual(env["PROFILE_EXPECTED_VALUES"], expected_values)
            self.assertEqual(metadata["check_unit_type"], "profile_scalar")
            self.assertEqual(metadata["profile_side"], side)
            self.assertEqual(metadata["profile_execution_mode"], "doitall")
            self.assertEqual(metadata["profile_doitall_penalty"], "10000000")
            self.assertEqual(metadata["profile_doitall_script"], "doitall.sh")

        unit_refs = [
            f"DRY-profile-model-{value}" for value in ("80", "90", "110", "120")
        ]
        merge_payload = merge["payload"]
        self.assertEqual(merge_payload["input_jobs"], unit_refs)
        self.assertEqual(merge_payload["env"]["PROFILE_EXPECTED_VALUES"], expected_values)
        self.assertEqual(merge_payload["env"]["PROFILE_EXECUTION_MODE"], "doitall")
        self.assertEqual(merge_payload["env"]["PROFILE_POST_MERGE_REPAIR"], "false")
        self.assertEqual(merge_payload["env"]["PROFILE_JAGGED_TOLERANCE"], "0.1")
        self.assertEqual(merge_payload["env"]["PROFILE_JAGGED_REPAIR_PASSES"], "2")
        self.assertEqual(merge_payload["env"]["PROFILE_MAX_JAGGED_REPAIRS"], "0")
        self.assertEqual(merge_payload["env"]["PROFILE_CONVERGENCE_EXPONENT"], "-3")
        self.assertEqual(merge_payload["env"]["PROFILE_REPAIR_CPUS"], "2")
        self.assertEqual(merge_payload["env"]["PROFILE_REPAIR_MEMORY_GB"], "16")
        self.assertEqual(
            merge_payload["env"]["PROFILE_REPAIR_MEMORY_PER_WORKER_GB"], "8"
        )
        self.assertEqual(merge_payload["metadata"]["profile_expected_values"], expected_values)
        self.assertEqual(merge_payload["metadata"]["profile_execution_mode"], "doitall")
        self.assertEqual(merge_payload["metadata"]["profile_parallel_mode"], "scalars")
        self.assertEqual(merge_payload["metadata"]["profile_doitall_penalty"], "10000000")

    def test_point_alias_uses_scalar_jobs_and_default_continuation_mode(self):
        with mock.patch.dict(
            os.environ,
            {
                "PROFILE_PARALLEL_MODE": "points",
                "PROFILE_VALUES": "95 100 105",
            },
            clear=True,
        ):
            specs = submit.check_unit_specs("profile", parallel_units=True)

        self.assertEqual([spec["metadata"]["check_unit"] for spec in specs], ["95", "105"])
        self.assertTrue(all(spec["env"]["PROFILE_CHAIN"] == "false" for spec in specs))
        self.assertTrue(all(spec["env"]["PROFILE_EXECUTION_MODE"] == "continuation" for spec in specs))

    def test_chain_mode_remains_selectable(self):
        with mock.patch.dict(
            os.environ,
            {
                "PROFILE_PARALLEL_MODE": "chains",
                "PROFILE_EXECUTION_MODE": "fitted_par",
                "PROFILE_VALUES": "90 100 110",
            },
            clear=True,
        ):
            specs = submit.check_unit_specs("profile", parallel_units=True)

        self.assertEqual(
            [spec["metadata"]["check_unit"] for spec in specs],
            ["downstream", "upstream"],
        )
        self.assertTrue(all(spec["env"]["PROFILE_CHAIN"] == "true" for spec in specs))
        self.assertTrue(all(spec["env"]["PROFILE_EXECUTION_MODE"] == "continuation" for spec in specs))

    def test_chain_merge_passes_explicit_repair_overrides(self):
        repair_env = {
            "PROFILE_PARALLEL_MODE": "chains",
            "PROFILE_VALUES": "90 100 110",
            "PROFILE_POST_MERGE_REPAIR": "false",
            "PROFILE_JAGGED_TOLERANCE": "0.25",
            "PROFILE_JAGGED_REPAIR_PASSES": "4",
            "PROFILE_MAX_JAGGED_REPAIRS": "9",
            "PROFILE_CONVERGENCE_EXPONENT": "-5",
            "PROFILE_REPAIR_CPUS": "3",
            "PROFILE_REPAIR_MEMORY_GB": "24",
            "PROFILE_REPAIR_MEMORY_PER_WORKER_GB": "6",
        }
        payloads = run_dry_run(
            [
                "submit_kflow_checks.py",
                "--checks", "profile",
                "--models", "model",
                "--input-jobs", "3001",
                "--parallel-units", "true",
                "--auto-attach", "false",
                "--dry-run",
            ],
            repair_env,
        )

        merge_env = payloads[-1]["payload"]["env"]
        for key, value in repair_env.items():
            if key != "PROFILE_VALUES":
                self.assertEqual(merge_env[key], value)

    def test_legacy_hbase_repair_resources_feed_the_generic_contract(self):
        with mock.patch.dict(os.environ, {
            "PROFILE_HBASE_REPAIR_PASSES": "5",
            "PROFILE_HBASE_REPAIR_CPUS": "6",
            "PROFILE_HBASE_REPAIR_MEMORY_GB": "30",
            "PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB": "10",
        }, clear=True):
            env = submit.resolved_profile_env([90.0, 110.0])

        self.assertEqual(env["PROFILE_JAGGED_REPAIR_PASSES"], "5")
        self.assertEqual(env["PROFILE_REPAIR_CPUS"], "6")
        self.assertEqual(env["PROFILE_REPAIR_MEMORY_GB"], "30")
        self.assertEqual(env["PROFILE_REPAIR_MEMORY_PER_WORKER_GB"], "10")
        self.assertEqual(env["PROFILE_HBASE_REPAIR_CPUS"], "6")
        self.assertEqual(env["PROFILE_HBASE_REPAIR_MEMORY_GB"], "30")
        self.assertEqual(env["PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB"], "10")

    def test_full_doitall_rejects_chain_parallelism_with_actionable_error(self):
        with mock.patch.dict(
            os.environ,
            {
                "PROFILE_PARALLEL_MODE": "chains",
                "PROFILE_EXECUTION_MODE": "doitall",
                "PROFILE_VALUES": "90 100 110",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(SystemExit, "PROFILE_PARALLEL_MODE=scalars"):
                submit.check_unit_specs("profile", parallel_units=True)
            with self.assertRaisesRegex(SystemExit, "PROFILE_PARALLEL_MODE=scalars"):
                submit.check_unit_specs("profile", parallel_units=False)

    def test_each_diagnostic_merge_is_its_own_direct_delta_attachment(self):
        for check in submit.DIRECT_MERGE_CHECKS:
            with self.subTest(check=check):
                payloads = run_dry_run([
                    "submit_kflow_checks.py",
                    "--checks", check,
                    "--models", "model",
                    "--input-jobs", "3001",
                    "--parallel-units", "false",
                    "--dry-run",
                ])

                self.assertEqual(
                    [item["task"] for item in payloads],
                    [
                        f"ofp-sam-bet-2026-check-{check}",
                        f"ofp-sam-bet-2026-check-{submit.MERGE_CHECKS[check]}",
                    ],
                )
                merge = payloads[-1]["payload"]
                unit_ref = merge["input_jobs"][1]
                self.assertTrue(unit_ref.startswith(f"DRY-{check}-model-"))
                self.assertEqual(merge["input_jobs"], ["3001", unit_ref])
                self.assertEqual(merge["env"]["ATTACH_OUTPUT_MODE"], "delta")
                self.assertEqual(merge["env"]["MODEL_BASE_INPUT_JOB"], "3001")
                self.assertEqual(merge["env"]["MODEL_ORIGINAL_BASE_INPUT_JOB"], "3001")
                self.assertEqual(merge["env"]["CHECK_INPUT_JOBS"], unit_ref)
                self.assertEqual(merge["env"]["ATTACH_CHECK_TYPES"], check)
                self.assertEqual(merge["env"]["ATTACH_UPDATED_CHECK_TYPES"], check)
                self.assertNotIn("ATTACH_RETAIN_CHECK_TYPES", merge["env"])
                self.assertEqual(merge["metadata"]["attached_work_parent_job"], "3001")
                self.assertTrue(merge["metadata"]["attached_work_latest"])
                self.assertTrue(merge["metadata"]["attached_output_overlay"])
                self.assertTrue(merge["metadata"]["attached_output_overlay_preserve_payload"])
                self.assertEqual(
                    merge["metadata"]["attached_output_overlay_mode"],
                    "diagnostics_with_payload",
                )
                self.assertTrue(merge["metadata"]["attached_output_overlay_replace_payload"])
                self.assertEqual(
                    merge["metadata"]["attached_output_overlay_replace_names"],
                    [check],
                )
                self.assertEqual(merge["metadata"]["attached_check_types"], [check])
                self.assertEqual(merge["metadata"]["previous_attached_output_job"], "")
                self.assertEqual(
                    merge["metadata"]["attached_work_slot"],
                    f"diagnostics:model:{check}",
                )
                self.assertTrue(merge["metadata"]["direct_merge_attach"])
                self.assertTrue(merge["metadata"]["independent_diagnostic_merge"])
                self.assertEqual(merge["metadata"]["attach_output_mode"], "delta")

    def test_multi_check_delta_merges_are_independent_without_common_collector(self):
        payloads = run_dry_run(
            [
                "submit_kflow_checks.py",
                "--checks", "hessian jitter",
                "--models", "model",
                "--input-jobs", "3001",
                "--parallel-units", "false",
                "--dry-run",
            ],
            {"JITTER_SEEDS": "1"},
        )

        tasks = [item["task"] for item in payloads]
        self.assertNotIn("ofp-sam-bet-2026-check-attach-checks", tasks)
        merges = [item["payload"] for item in payloads if item["task"].endswith("-merge")]
        self.assertEqual(len(merges), 2)
        hessian_merge, jitter_merge = merges
        self.assertEqual(hessian_merge["input_jobs"][0], "3001")
        self.assertEqual(hessian_merge["metadata"]["attached_check_types"], ["hessian"])
        self.assertEqual(hessian_merge["metadata"]["previous_attached_output_job"], "")
        self.assertEqual(jitter_merge["input_jobs"][0], "3001")
        self.assertIn("DRY-jitter-model-unit", jitter_merge["input_jobs"])
        self.assertNotIn("DRY-hessian-merge-model-merge", jitter_merge["input_jobs"])
        self.assertEqual(jitter_merge["env"]["MODEL_BASE_INPUT_JOB"], "3001")
        self.assertEqual(jitter_merge["env"]["MODEL_ORIGINAL_BASE_INPUT_JOB"], "3001")
        self.assertNotIn("ATTACH_RETAIN_CHECK_TYPES", jitter_merge["env"])
        self.assertEqual(
            jitter_merge["metadata"]["attached_check_types"],
            ["jitter"],
        )
        self.assertEqual(
            jitter_merge["metadata"]["attached_output_overlay_replace_names"],
            ["jitter"],
        )
        self.assertEqual(jitter_merge["metadata"]["attached_work_parent_job"], "3001")
        self.assertEqual(jitter_merge["metadata"]["previous_attached_output_job"], "")
        self.assertNotEqual(
            hessian_merge["metadata"]["attached_work_slot"],
            jitter_merge["metadata"]["attached_work_slot"],
        )

    def test_delta_rerun_uses_only_its_same_slot_predecessor(self):
        payloads = run_dry_run(
            [
                "submit_kflow_checks.py",
                "--checks", "hessian jitter",
                "--models", "model",
                "--input-jobs", "3001",
                "--parallel-units", "false",
                "--dry-run",
            ],
            {
                "JITTER_SEEDS": "1",
                "KFLOW_PREVIOUS_ATTACHED_OUTPUT_BY_SLOT": json.dumps({
                    "diagnostics:model:hessian": {"output_job": "2999"},
                }),
            },
        )

        tasks = [item["task"] for item in payloads]
        self.assertNotIn("ofp-sam-bet-2026-check-attach-checks", tasks)
        merges = [item["payload"] for item in payloads if item["task"].endswith("-merge")]
        hessian_merge, jitter_merge = merges
        self.assertEqual(hessian_merge["input_jobs"][0], "3001")
        self.assertEqual(hessian_merge["metadata"]["previous_attached_output_job"], "2999")
        self.assertEqual(hessian_merge["metadata"]["same_slot_predecessor_job"], "2999")
        self.assertNotIn("2999", jitter_merge["input_jobs"])
        self.assertEqual(jitter_merge["input_jobs"][0], "3001")
        self.assertEqual(jitter_merge["env"]["MODEL_BASE_INPUT_JOB"], "3001")
        self.assertEqual(jitter_merge["env"]["MODEL_ORIGINAL_BASE_INPUT_JOB"], "3001")
        self.assertEqual(jitter_merge["metadata"]["attached_check_types"], ["jitter"])
        self.assertEqual(jitter_merge["metadata"]["previous_attached_output_job"], "")

    def test_all_six_diagnostic_delta_merges_are_independent_attachments(self):
        check_order = list(submit.DIRECT_MERGE_CHECKS)
        payloads = run_dry_run([
            "submit_kflow_checks.py",
            "--checks", " ".join(check_order),
            "--models", "model",
            "--input-jobs", "3001",
            "--parallel-units", "false",
            "--dry-run",
        ])

        self.assertNotIn(
            "ofp-sam-bet-2026-check-attach-checks",
            [item["task"] for item in payloads],
        )
        merge_items = [item for item in payloads if item["task"].endswith("-merge")]
        self.assertEqual(len(merge_items), len(check_order))
        slots = []
        merge_refs = {
            f"DRY-{submit.MERGE_CHECKS[check]}-model-merge"
            for check in check_order
        }
        for check, item in zip(check_order, merge_items):
            merge = item["payload"]
            self.assertEqual(merge["input_jobs"][0], "3001")
            self.assertFalse(merge_refs.intersection(merge["input_jobs"]))
            self.assertEqual(merge["metadata"]["previous_attached_output_job"], "")
            self.assertEqual(merge["metadata"]["attached_work_parent_job"], "3001")
            self.assertEqual(merge["metadata"]["attached_check_types"], [check])
            self.assertEqual(
                merge["metadata"]["attached_output_overlay_replace_names"],
                [check],
            )
            self.assertTrue(merge["metadata"]["attached_output_overlay_preserve_payload"])
            self.assertTrue(merge["metadata"]["independent_diagnostic_merge"])
            slots.append(merge["metadata"]["attached_work_slot"])

        self.assertEqual(len(set(slots)), len(check_order))

    def test_full_mode_keeps_the_standalone_attach_collector(self):
        argv = [
            "submit_kflow_checks.py",
            "--checks", "hessian",
            "--models", "model",
            "--input-jobs", "3001",
            "--parallel-units", "false",
            "--dry-run",
        ]
        output = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"ATTACH_OUTPUT_MODE": "full"}, clear=True),
            mock.patch.object(sys, "argv", argv),
            redirect_stdout(output),
        ):
            self.assertEqual(submit.main(), 0)

        decoder = json.JSONDecoder()
        payloads = []
        remaining = output.getvalue().lstrip()
        while remaining:
            value, end = decoder.raw_decode(remaining)
            payloads.append(value)
            remaining = remaining[end:].lstrip()

        tasks = [item["task"] for item in payloads]
        self.assertIn("ofp-sam-bet-2026-check-attach-checks", tasks)
        attach = payloads[tasks.index("ofp-sam-bet-2026-check-attach-checks")]["payload"]
        self.assertEqual(attach["env"]["ATTACH_OUTPUT_MODE"], "full")
        self.assertFalse(attach["metadata"]["attached_output_overlay"])
        self.assertEqual(attach["metadata"]["attached_output_overlay_mode"], "standalone")
        self.assertFalse(attach["metadata"]["attached_output_overlay_replace_payload"])
        self.assertEqual(attach["metadata"]["attached_output_overlay_replace_names"], [])


class AttachedOutputDiscoveryTests(unittest.TestCase):
    def test_latest_attached_output_is_used_only_when_child_is_safe(self):
        parent = {"metadata": {"attached_work_latest": {"output_job": "2999"}}}

        def discover(child):
            with mock.patch.object(submit, "api_job", side_effect=[parent, child]):
                return submit.latest_attached_output_job("https://kflow.test", "token", "3001")

        self.assertEqual(
            discover({
                "job_number": "2999",
                "status": "completed",
                "metadata": {"attached_work_parent_job": "3001"},
            }),
            "2999",
        )
        self.assertEqual(
            discover({
                "job_number": "2999",
                "status": "failed",
                "metadata": {"attached_work_parent_job": "3001"},
            }),
            "",
        )
        self.assertEqual(
            discover({
                "job_number": "2999",
                "status": "completed",
                "metadata": {"attached_work_parent_job": "different-base"},
            }),
            "",
        )

    def test_latest_same_slot_outputs_are_validated_independently(self):
        jobs = {
            "3001": {
                "metadata": {
                    "attached_work_latest_by_slot": {
                        "diagnostics-model-hessian": {"output_job": "2999"},
                        "diagnostics-model-jitter": "2998",
                        "diagnostics-model-retro": {"output_job": "2997"},
                    }
                }
            },
            "2999": {
                "status": "completed",
                "metadata": {
                    "attached_work_parent_job": "3001",
                    "attached_work_slot": "diagnostics:model:hessian",
                },
            },
            "2998": {
                "status": "success",
                "metadata": {
                    "attached_work_parent_job": "3001",
                    "attached_work_slot": "diagnostics:model:jitter",
                },
            },
            "2997": {
                "status": "completed",
                "metadata": {
                    "attached_work_parent_job": "different-base",
                    "attached_work_slot": "diagnostics:model:retro",
                },
            },
        }
        with mock.patch.object(submit, "api_job", side_effect=lambda _url, _token, ref: jobs[str(ref)]):
            latest = submit.latest_attached_output_jobs_by_slot(
                "https://kflow.test", "token", "3001"
            )
        self.assertEqual(latest, {
            "diagnostics-model-hessian": "2999",
            "diagnostics-model-jitter": "2998",
        })


class AttachedTaskDefaultsTests(unittest.TestCase):
    def test_profile_tasks_accept_explicit_convergence_controls(self):
        for folder in ("profile", "profile-merge"):
            with self.subTest(folder=folder):
                task = (ROOT / folder / "kflow.yaml").read_text(encoding="utf-8")
                self.assertIn('PROFILE_CONVERGENCE_EXPONENT: "-3"', task)
                self.assertIn('PROFILE_MAX_GRAD_THRESHOLD: ""', task)
                self.assertEqual(task.count("PROFILE_MAX_GRAD_THRESHOLD"), 2)

    def test_profile_task_keeps_chain_continuation_defaults(self):
        task = (ROOT / "profile" / "kflow.yaml").read_text(encoding="utf-8")
        self.assertIn("PROFILE_PARALLEL_MODE: chains", task)
        self.assertIn("PROFILE_EXECUTION_MODE: continuation", task)
        self.assertIn('PROFILE_CHAIN: "true"', task)
        self.assertIn("PROFILE_PRESET: robust_fast", task)
        self.assertIn('PROFILE_INVALID_RETRY_PASSES: "1"', task)
        self.assertIn('PROFILE_RETRY_JAGGED: "false"', task)
        self.assertIn('PROFILE_JAGGED_REPAIR_PASSES: "0"', task)
        self.assertIn('PROFILE_MAX_JAGGED_REPAIRS: "0"', task)

    def test_total_average_biomass_default_matches_af172_zero(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            env = submit.resolved_profile_env([90.0, 110.0])
        self.assertEqual(env["PROFILE_NAME"], "total_average_biomass")
        self.assertEqual(env["PROFILE_AF172"], "0")
        self.assertEqual(env["PROFILE_CONVERGENCE_EXPONENT"], "-3")
        self.assertEqual(env["PROFILE_POST_MERGE_REPAIR"], "false")
        self.assertEqual(env["PROFILE_REVERSE_ONCE"], "true")
        self.assertEqual(env["PROFILE_INVALID_RETRY_PASSES"], "1")
        self.assertEqual(env["PROFILE_JAGGED_REPAIR_PASSES"], "2")
        self.assertEqual(env["PROFILE_MAX_JAGGED_REPAIRS"], "0")
        self.assertEqual(env["PROFILE_REPAIR_CPUS"], "2")
        self.assertEqual(env["PROFILE_REPAIR_MEMORY_GB"], "16")
        self.assertEqual(env["PROFILE_REPAIR_MEMORY_PER_WORKER_GB"], "8")

    def test_profile_units_defer_shape_repair_to_the_merge(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            env = submit.resolved_profile_unit_env([90.0, 110.0])
        self.assertEqual(env["PROFILE_RETRY_INVALID"], "true")
        self.assertEqual(env["PROFILE_INVALID_RETRY_PASSES"], "1")
        self.assertEqual(env["PROFILE_RETRY_JAGGED"], "false")
        self.assertEqual(env["PROFILE_JAGGED_REPAIR_PASSES"], "0")
        self.assertEqual(env["PROFILE_MAX_JAGGED_REPAIRS"], "0")

    def test_profile_tasks_use_stage_specific_resources(self):
        generic = {"cpus": 9, "memory": "99GB", "disk": "7GB"}
        with mock.patch.dict(os.environ, {}, clear=True):
            unit = submit.check_task_resources("profile", generic)
            merge = submit.check_task_resources("profile-merge", generic)
            jitter = submit.check_task_resources("jitter", generic)
        self.assertEqual(unit, {"cpus": 1, "memory": "8GB", "disk": "7GB"})
        self.assertEqual(merge, {"cpus": 1, "memory": "4GB", "disk": "7GB"})
        self.assertEqual(jitter, generic)

    def test_absolute_profile_targets_keep_the_fitted_quantity_anchor(self):
        with mock.patch.dict(os.environ, {
            "PROFILE_VALUE_MODE": "absolute",
            "PROFILE_TARGET_VALUES": "2500000 2600000 2700000 2800000",
            "PROFILE_TARGET_CENTER": "2677499",
        }, clear=True):
            values = submit.profile_values_from_env()
            env = submit.resolved_profile_env(values)

        self.assertEqual(env["PROFILE_VALUE_MODE"], "absolute")
        self.assertEqual(
            env["PROFILE_TARGET_VALUES"],
            "2500000 2600000 2700000 2800000",
        )
        self.assertNotIn("PROFILE_VALUES", env)
        self.assertEqual(env["PROFILE_TARGET_CENTER"], "2677499")
        self.assertEqual(
            env["PROFILE_EXPECTED_VALUES"],
            "2500000 2600000 2677499 2700000 2800000",
        )

        task = (ROOT / "profile" / "kflow.yaml").read_text(encoding="utf-8")
        self.assertIn("PROFILE_NAME: total_average_biomass", task)

    def test_manual_attach_task_defaults_to_standalone_full_output(self):
        task = (ROOT / "attach-checks" / "kflow.yaml").read_text(encoding="utf-8")
        self.assertIn("ATTACH_OUTPUT_MODE: full", task)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertNotIn("KFLOW_DIRECT_MERGE_ATTACH", readme)
        self.assertIn("`attach-checks` Kflow task defaults to `full`", readme)


if __name__ == "__main__":
    unittest.main()
