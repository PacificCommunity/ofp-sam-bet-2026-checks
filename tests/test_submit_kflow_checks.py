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
    def test_profile_tasks_accept_the_explicit_gradient_threshold(self):
        for folder in ("profile", "profile-merge"):
            with self.subTest(folder=folder):
                task = (ROOT / folder / "kflow.yaml").read_text(encoding="utf-8")
                self.assertIn('PROFILE_MAX_GRAD_THRESHOLD: "0.001"', task)
                self.assertEqual(task.count("PROFILE_MAX_GRAD_THRESHOLD"), 2)

    def test_manual_attach_task_defaults_to_standalone_full_output(self):
        task = (ROOT / "attach-checks" / "kflow.yaml").read_text(encoding="utf-8")
        self.assertIn("ATTACH_OUTPUT_MODE: full", task)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertNotIn("KFLOW_DIRECT_MERGE_ATTACH", readme)
        self.assertIn("`attach-checks` Kflow task defaults to `full`", readme)


if __name__ == "__main__":
    unittest.main()
