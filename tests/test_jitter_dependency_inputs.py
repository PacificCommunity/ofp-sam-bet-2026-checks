import csv
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "R" / "model_output_adapter.R"
RUN_CHECK = ROOT / "R" / "run_check.R"


def fitted_par_bytes(label: str, objective: float, npars: int) -> bytes:
    """Smallest PAR-like fixture accepted as a completed fitted model."""
    return textwrap.dedent(
        f"""\
        # fixture
        {label}
        # Objective function value
        {objective}
        # The number of parameters
        {npars}
        """
    ).encode("utf-8")


def md5_bytes(value: bytes) -> str:
    return hashlib.md5(value).hexdigest()


class JitterDependencyInputTests(unittest.TestCase):
    maxDiff = None

    def run_r(self, expression: str, *args: Path, env=None, check=True):
        process_env = os.environ.copy()
        if env:
            process_env.update({str(key): str(value) for key, value in env.items()})
        return subprocess.run(
            ["Rscript", "-e", expression, *map(str, args)],
            cwd=ROOT,
            env=process_env,
            text=True,
            capture_output=True,
            check=check,
        )

    def write_payload(self, path: Path, par: Path, indepvar: Path | None) -> None:
        expression = r'''
args <- commandArgs(trailingOnly = TRUE)
raw_file <- function(path) {
  readBin(path, what = "raw", n = file.info(path)$size)
}
files <- list(
  par = list(bytes = raw_file(args[[2L]]), compression = "none")
)
if (!identical(args[[3L]], "-")) {
  files$indepvar <- list(
    bytes = raw_file(args[[3L]]), compression = "none"
  )
}
saveRDS(list(artifacts = list(files = files)), args[[1L]])
'''
        self.run_r(expression, path, par, indepvar or Path("-"))

    def make_compact_case(self, root: Path):
        compact = root / "compact"
        source = compact / "mfcl-inputs"
        source.mkdir(parents=True)
        (source / "case.frq").write_bytes(b"source frequency fixture\n")
        (source / "00.par").write_bytes(b"source makepar fixture\n")
        (source / "indepvar.rpt").write_bytes(b"stale source indepvar\n")
        return compact, source

    def stage_case(self, root: Path, compact: Path, final_par="direct.par"):
        work = root / "work"
        output = root / "outputs"
        expression = r'''
args <- commandArgs(trailingOnly = TRUE)
source(args[[1L]])
row <- data.frame(
  candidate_type = "indexed",
  compact_dir = args[[2L]],
  model_key = "fixture-model",
  model_label = "fixture-model",
  model_source = "",
  step_id = "",
  final_par = args[[3L]],
  stringsAsFactors = FALSE
)
stage_selected_model(row, work_dir = args[[4L]], output_dir = args[[5L]])
'''
        self.run_r(expression, ADAPTER, compact, Path(final_par), work, output)
        with (output / "check-input.csv").open(newline="", encoding="utf-8") as handle:
            manifest = next(csv.DictReader(handle))
        return work / "case", manifest

    def test_phase1_jitter_uses_the_staged_fitted_par_not_a_latest_rescan(self) -> None:
        runner = RUN_CHECK.read_text(encoding="utf-8")
        start = runner.rindex('} else if (identical(check_type, "jitter")) {')
        end = runner.index('\n} else if (identical(check_type, "retro"))', start)
        jitter = runner[start:end]

        self.assertIn("staged_fitted_par <- prepared$start_par", runner)
        self.assertIn('if (!identical(check_type, "jitter")) {', runner)
        self.assertIn("par = staged_fitted_par", jitter)
        self.assertIn("jitter_args$fitted_indepvar <- staged_fitted_indepvar", jitter)
        self.assertNotIn("par = check_start_par", jitter)
        self.assertIn('jitter_args$base_stage <- "phase1"', jitter)

    def test_payload_pair_wins_over_direct_and_source_stale_pair(self) -> None:
        payload_par = fitted_par_bytes("payload fitted PAR", 101.25, 3)
        direct_par = fitted_par_bytes("stale direct PAR", 909.5, 4)
        payload_indepvar = b"payload fitted indepvar\n1 2 3\n"

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            compact, source = self.make_compact_case(root)
            (compact / "direct.par").write_bytes(direct_par)
            (compact / "indepvar.rpt").write_bytes(b"stale direct indepvar\n")
            payload_par_file = root / "payload.par"
            payload_indepvar_file = root / "payload-indepvar.rpt"
            payload_par_file.write_bytes(payload_par)
            payload_indepvar_file.write_bytes(payload_indepvar)
            self.write_payload(
                compact / "model_payload.rds", payload_par_file, payload_indepvar_file
            )

            staged, manifest = self.stage_case(root, compact)

            self.assertEqual((staged / "final.par").read_bytes(), payload_par)
            self.assertEqual((staged / "indepvar.rpt").read_bytes(), payload_indepvar)
            self.assertNotEqual((staged / "final.par").read_bytes(), direct_par)
            self.assertNotEqual(
                (staged / "indepvar.rpt").read_bytes(),
                (source / "indepvar.rpt").read_bytes(),
            )
            self.assertEqual(manifest["start_par_selection"], "payload_fitted_par")
            self.assertEqual(
                manifest["fitted_indepvar_selection"], "payload_fitted_indepvar"
            )
            self.assertEqual(manifest["start_par_md5"], md5_bytes(payload_par))
            self.assertEqual(
                manifest["fitted_indepvar_md5"], md5_bytes(payload_indepvar)
            )

    def test_payload_par_without_indepvar_discards_stale_reports_for_fresh_probe(self) -> None:
        payload_par = fitted_par_bytes("payload PAR without mask", 202.5, 5)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            compact, _source = self.make_compact_case(root)
            (compact / "direct.par").write_bytes(
                fitted_par_bytes("stale direct PAR", 808.0, 6)
            )
            (compact / "indepvar.rpt").write_bytes(b"stale compact indepvar\n")
            payload_par_file = root / "payload.par"
            payload_par_file.write_bytes(payload_par)
            self.write_payload(compact / "model_payload.rds", payload_par_file, None)

            staged, manifest = self.stage_case(root, compact)

            self.assertEqual((staged / "final.par").read_bytes(), payload_par)
            self.assertFalse((staged / "indepvar.rpt").exists())
            self.assertEqual(manifest["start_par_selection"], "payload_fitted_par")
            self.assertEqual(manifest["fitted_indepvar_selection"], "")
            self.assertEqual(manifest["fitted_indepvar_md5"], "")
            self.assertEqual(manifest["start_par_md5"], md5_bytes(payload_par))

        runner = RUN_CHECK.read_text(encoding="utf-8")
        self.assertIn('"fresh_fitted_native_xinit_source_registry"', runner)
        self.assertNotIn('"staged_case_indepvar_fallback"', ADAPTER.read_text(encoding="utf-8"))

    def test_direct_completed_par_accepts_only_colocated_compact_indepvar(self) -> None:
        direct_par = fitted_par_bytes("direct completed PAR", 303.75, 7)
        compact_indepvar = b"compact full-fit indepvar\n7 8 9\n"

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            compact, source = self.make_compact_case(root)
            (compact / "direct.par").write_bytes(direct_par)
            (compact / "indepvar.rpt").write_bytes(compact_indepvar)

            staged, manifest = self.stage_case(root, compact)

            self.assertEqual((staged / "final.par").read_bytes(), direct_par)
            self.assertEqual((staged / "indepvar.rpt").read_bytes(), compact_indepvar)
            self.assertNotEqual(
                (staged / "indepvar.rpt").read_bytes(),
                (source / "indepvar.rpt").read_bytes(),
            )
            self.assertEqual(manifest["start_par_selection"], "direct_fitted_par")
            self.assertEqual(
                manifest["fitted_indepvar_selection"], "compact_fitted_indepvar"
            )
            self.assertEqual(manifest["start_par_md5"], md5_bytes(direct_par))
            self.assertEqual(
                manifest["fitted_indepvar_md5"], md5_bytes(compact_indepvar)
            )

    def test_00_par_only_jitter_preflight_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            case = root / "case"
            case.mkdir()
            (case / "case.frq").write_bytes(b"frequency fixture\n")
            original = b"makepar-only 00.par without fit summary\n"
            (case / "00.par").write_bytes(original)
            work = root / "work"
            output = root / "outputs"
            env = os.environ.copy()
            env.update(
                {
                    "MODEL_INPUT_ROOT": str(case),
                    "WORK_DIR": str(work),
                    "OUTPUT_DIR": str(output),
                    "PROGRAM_PATH": "/bin/true",
                    "CHECK_ENRICH_PAYLOADS": "false",
                    "CHECK_REQUIRE_PAYLOAD_REFRESH": "false",
                }
            )
            result = subprocess.run(
                ["Rscript", str(RUN_CHECK), "jitter"],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                "Jitter requires a completed parent fitted PAR",
                result.stdout + result.stderr,
            )
            with (output / "check-input.csv").open(
                newline="", encoding="utf-8"
            ) as handle:
                manifest = next(csv.DictReader(handle))
            self.assertEqual(
                manifest["start_par_selection"], "direct_par_without_fit_summary"
            )
            self.assertEqual(manifest["start_par_md5"], md5_bytes(original))

    def test_jitter_mask_provenance_and_checksums_are_manifested(self) -> None:
        runner = RUN_CHECK.read_text(encoding="utf-8")
        adapter = ADAPTER.read_text(encoding="utf-8")
        task = (ROOT / "jitter" / "kflow.yaml").read_text(encoding="utf-8")

        self.assertIn('jitter_fitted_mask_par_md5 = file_md5(staged_fitted_par)', runner)
        self.assertIn('jitter_fitted_indepvar_md5 = file_md5(staged_fitted_indepvar)', runner)
        self.assertIn(
            '"validated_parent_full_fit_indepvar"',
            runner,
        )
        self.assertIn('"post_phase1_current_values"', runner)
        self.assertIn('env("JITTER_STRICT_ACTIVE_MASK", "false")', runner)
        self.assertIn('JITTER_STRICT_ACTIVE_MASK: "false"', task)
        self.assertIn('input_file_manifest = basename(input_inventory$path)', adapter)
        self.assertIn('start_par_md5 = file_md5(start_par)', adapter)

    def test_runtime_package_fallbacks_use_one_consistent_pin_pair(self) -> None:
        files = [
            ROOT / "run.sh",
            ROOT / "scripts" / "submit_kflow_checks.py",
            ROOT / "local_apps.yaml",
            *ROOT.glob("*/kflow.yaml"),
        ]
        kit_refs = set()
        shiny_refs = set()
        for path in files:
            text = path.read_text(encoding="utf-8")
            kit_refs.update(re.findall(r"ofp-sam-mfclkit@([0-9a-f]{40})", text))
            shiny_refs.update(re.findall(r"mfclshiny@([0-9a-f]{40})", text))

        self.assertEqual(len(kit_refs), 1, kit_refs)
        self.assertEqual(len(shiny_refs), 1, shiny_refs)


if __name__ == "__main__":
    unittest.main()
