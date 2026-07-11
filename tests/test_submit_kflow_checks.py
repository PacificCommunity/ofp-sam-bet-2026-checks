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

    def test_species_metadata_reaches_unit_merge_and_attach_jobs(self):
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

        self.assertEqual(len(payloads), 3)
        for item in payloads:
            env = item["payload"]["env"]
            self.assertEqual(env["FLOW_SPECIES"], "YFT")
            self.assertEqual(env["FLOW_SPECIES_LABEL"], "yellowfin tuna")
            self.assertEqual(env["FLOW_ASSESSMENT_YEAR"], "2027")


if __name__ == "__main__":
    unittest.main()
