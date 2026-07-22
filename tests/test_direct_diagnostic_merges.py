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

    @classmethod
    def setUpClass(cls) -> None:
        cls.mock_package_tmp = tempfile.TemporaryDirectory()
        root = Path(cls.mock_package_tmp.name)
        package = root / "mfclkit"
        library = root / "library"
        (package / "R").mkdir(parents=True)
        library.mkdir()
        (package / "DESCRIPTION").write_text(
            "Package: mfclkit\nVersion: 999.0.0\nTitle: Merge Test Mock\n"
            "Description: Minimal direct merge test double.\n"
            "License: MIT\nEncoding: UTF-8\n",
            encoding="utf-8",
        )
        exports = [
            "mfk_close_quantity_profile",
            "mfk_model_quantity",
            "mfk_native_backend",
            "mfk_profile_conflict_metrics",
            "mfk_quantity_profile_from_model",
            "mfk_read_profile_points",
        ]
        (package / "NAMESPACE").write_text(
            "\n".join(f"export({name})" for name in exports) + "\n",
            encoding="utf-8",
        )
        (package / "R" / "mock.R").write_text(
            r'''
mock_value <- function(x, name, default = NA) {
  value <- tryCatch(x[[name]], error = function(e) NULL)
  if (is.null(value) || !length(value)) default else value[[1L]]
}

mfk_model_quantity <- function(...) NA_real_

mfk_native_backend <- function(program_path = "mfclo64", ...) {
  list(program_path = program_path)
}

mfk_quantity_profile_from_model <- function(
    model_dir, name, values, quantity, quantity_type, base_quantity = NULL,
    target = NA_real_, scalar_is_percent = TRUE, Af172 = 0L, Af173 = 0L,
    Af174 = 0L, penalty = 1e7, reps = 2000L,
    convergence_exponent = -3L, ...) {
  data.frame(
    name = rep(name, length(values)), scalar = values,
    quantity = rep(quantity, length(values)),
    quantity_type = rep(quantity_type, length(values)),
    stringsAsFactors = FALSE
  )
}

mfk_read_profile_points <- function(profile_dir) {
  dirs <- list.dirs(profile_dir, recursive = FALSE, full.names = TRUE)
  dirs <- dirs[grepl("^scalar_", basename(dirs))]
  rows <- lapply(dirs, function(dir) {
    info <- tryCatch(readRDS(file.path(dir, "profile_point_info.rds")),
                     error = function(e) list())
    data.frame(
      profile = as.character(mock_value(info, "profile", basename(profile_dir))),
      scalar = suppressWarnings(as.numeric(mock_value(
        info, "scalar", sub("^scalar_", "", basename(dir))
      ))),
      total_nll = suppressWarnings(as.numeric(mock_value(info, "total_nll"))),
      profile_nll = suppressWarnings(as.numeric(mock_value(info, "profile_nll"))),
      run_status = as.character(mock_value(info, "run_status", "unknown")),
      run_completed = as.logical(mock_value(info, "run_completed", FALSE)),
      convergence_status = as.character(mock_value(
        info, "convergence_status", "unknown"
      )),
      converged = as.logical(mock_value(info, "converged", FALSE)),
      point_valid = as.logical(mock_value(info, "point_valid", FALSE)),
      target_attained = as.logical(mock_value(info, "target_attained", FALSE)),
      objective_source = as.character(mock_value(info, "objective_source", NA)),
      output_par = as.character(mock_value(info, "output_par", NA)),
      folder = normalizePath(dir, winslash = "/", mustWork = FALSE),
      stringsAsFactors = FALSE
    )
  })
  if (!length(rows)) return(data.frame(stringsAsFactors = FALSE))
  do.call(rbind, rows)
}

mfk_profile_conflict_metrics <- function(points, ...) {
  data.frame(
    profile = if (nrow(points)) as.character(points$profile[[1L]]) else "profile",
    qc = "Good", reason = "", stringsAsFactors = FALSE
  )
}

mfk_close_quantity_profile <- function(
    backend, input_dir, model_dir, profile, par = NULL, frq = NULL,
    preset = "three_stage", center = 100, penalties = NULL, reps = NULL,
    search_threshold = 1e-3, target_rel_tolerance = 0.001,
    continuation_reps = 1000L, jagged_tolerance = 0.1,
    repair_passes = 2L, max_runs = 50L, max_scalars = 20L,
    final_polish = TRUE, polish_threshold = 1e-4, parallel = FALSE,
    cpus = 1L, cpus_per_worker = 1L, memory_gb = 8,
    memory_gb_per_worker = 8, run_messages = TRUE) {
  call_file <- Sys.getenv("MFK_MOCK_CALL_FILE", "")
  call <- as.list(environment())
  if (nzchar(call_file)) saveRDS(call, call_file)
  profile_name <- if (nrow(profile)) as.character(profile$name[[1L]]) else "profile"
  audit_path <- file.path(
    model_dir, "profile", profile_name, "quantity-profile-closure-audit.rds"
  )
  dir.create(dirname(audit_path), recursive = TRUE, showWarnings = FALSE)
  suspects <- suppressWarnings(as.numeric(strsplit(
    Sys.getenv("MFK_MOCK_SUSPECT_SCALARS", ""), "[ ,]+"
  )[[1L]]))
  suspects <- suspects[is.finite(suspects)]
  stop_reason <- Sys.getenv("MFK_MOCK_STOP_REASON", "clean_profile")
  result <- list(
    schema = "mfclkit.quantity_profile_closure.v1",
    status = "completed", stop_reason = stop_reason,
    attempted_scalars = numeric(), promoted_scalars = numeric(),
    audit = data.frame(), before_qc = list(),
    after_qc = list(suspect_scalars = suspects),
    budget = list(run_budget_exhausted = FALSE, scalar_budget_exhausted = FALSE),
    audit_path = audit_path
  )
  saveRDS(result, audit_path, compress = "xz")
  result
}
''',
            encoding="utf-8",
        )
        subprocess.run(
            ["R", "CMD", "INSTALL", "--library", str(library), str(package)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        cls.mock_library = library

    @classmethod
    def tearDownClass(cls) -> None:
        cls.mock_package_tmp.cleanup()

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
        }
        if check_type == "profile":
            env.update({
                "PROFILE_INCLUDE_BASE_ANCHOR": "false",
                "PROFILE_EXPECTED_VALUES": "90",
            })
        env.update(extra_env or {})
        return subprocess.run(
            ["Rscript", "R/merge_check.R"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )

    def mock_env(self) -> dict[str, str]:
        return {"R_LIBS_USER": str(self.mock_library)}

    def write_compact_base_payload(
        self,
        base_model: Path,
        par_text: str,
        objective: float = 100.0,
        max_grad: float = 0.0001,
        completed: bool = True,
    ) -> None:
        subprocess.run(
            [
                "Rscript",
                "-e",
                (
                    "args <- commandArgs(TRUE); "
                    "payload <- list(data=list(info=list(source='base')), "
                    "obj_fun=as.numeric(args[[3]]), max_grad=as.numeric(args[[4]]), "
                    "actual_quantity=100, run_completed=as.logical(args[[5]]), "
                    "artifacts=list(files=list(par=list("
                    "bytes=charToRaw(args[[2]]), compression='none')))); "
                    "saveRDS(payload, args[[1]])"
                ),
                str(base_model / "model_payload.rds"),
                par_text,
                str(objective),
                str(max_grad),
                "TRUE" if completed else "FALSE",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )

    def write_profile_point(
        self,
        unit_model: Path,
        scalar: int,
        nll: float,
        source: str = "zero_penalty_harvest_par",
        valid: bool = True,
        par_text: str = "profile par\n",
    ) -> Path:
        point_dir = (
            unit_model / "profile" / "adult_biomass" / f"scalar_{scalar}"
        )
        point_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "Rscript",
                "-e",
                (
                    "args <- commandArgs(TRUE); dir.create(args[[1]], recursive=TRUE, "
                    "showWarnings=FALSE); valid <- as.logical(args[[5]]); "
                    "info <- list(profile='adult_biomass', scalar=as.numeric(args[[2]]), "
                    "total_nll=as.numeric(args[[3]]), profile_nll=as.numeric(args[[3]]), "
                    "objective_source=args[[4]], point_valid=valid, run_completed=valid, "
                    "run_status=if (valid) 'completed' else 'failed', "
                    "convergence_status=if (valid) 'converged' else 'not_converged', "
                    "converged=valid, target_attained=valid, output_par='final.par', "
                    "base_anchor=identical(args[[4]], 'fitted_model_par'), "
                    "row=data.frame(profile='adult_biomass', quantity='avg_bio', "
                    "quantity_type=2L, base_quantity=100, Af172=0L, Af173=0L, Af174=0L)); "
                    "saveRDS(info, file.path(args[[1]], 'profile_point_info.rds')); "
                    "saveRDS(info, file.path(args[[1]], 'profile_payload.rds')); "
                    "writeLines(args[[6]], file.path(args[[1]], 'final.par'))"
                ),
                str(point_dir),
                str(scalar),
                str(nll),
                source,
                "TRUE" if valid else "FALSE",
                par_text,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        return point_dir

    def test_compact_fitted_anchor_par_is_restored(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, base_model = self.make_case(root, "profile")
            (base_model / "final.par").unlink()
            self.write_compact_base_payload(base_model, "restored compact par\n")

            self.run_merge(
                input_root,
                output_dir,
                "profile",
                extra_env={
                    **self.mock_env(),
                    "PROFILE_INCLUDE_BASE_ANCHOR": "true",
                    "PROFILE_NAME": "adult_biomass",
                    "PROFILE_EXPECTED_VALUES": "100",
                    "PROFILE_POST_MERGE_REPAIR": "false",
                },
            )

            anchor = (
                output_dir
                / "models/model/profile/adult_biomass/scalar_100"
            )
            self.assertEqual(
                (anchor / "final.par").read_text(encoding="utf-8"),
                "restored compact par\n",
            )
            subprocess.run(
                [
                    "Rscript",
                    "-e",
                    (
                        "x <- readRDS(commandArgs(TRUE)[1]); "
                        "stopifnot(isTRUE(x$base_anchor), isTRUE(x$point_valid), "
                        "identical(x$objective_source, 'fitted_model_par'), "
                        "identical(x$output_par, 'final.par'))"
                    ),
                    str(anchor / "profile_point_info.rds"),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            )

    def test_invalid_scalar_100_is_replaced_by_compact_fitted_anchor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, base_model = self.make_case(root, "profile")
            unit_model = input_root / "4001/outputs/checks/profile/model"
            self.write_profile_point(
                unit_model,
                100,
                500,
                source="penalized_fallback",
                valid=False,
                par_text="invalid scalar par\n",
            )
            (base_model / "final.par").unlink()
            self.write_compact_base_payload(base_model, "replacement fitted par\n")

            self.run_merge(
                input_root,
                output_dir,
                "profile",
                extra_env={
                    **self.mock_env(),
                    "PROFILE_INCLUDE_BASE_ANCHOR": "true",
                    "PROFILE_EXPECTED_VALUES": "100",
                    "PROFILE_POST_MERGE_REPAIR": "false",
                },
            )

            anchor = output_dir / "models/model/profile/adult_biomass/scalar_100"
            self.assertEqual(
                (anchor / "final.par").read_text(encoding="utf-8"),
                "replacement fitted par\n",
            )
            subprocess.run(
                [
                    "Rscript",
                    "-e",
                    (
                        "x <- readRDS(commandArgs(TRUE)[1]); "
                        "stopifnot(isTRUE(x$base_anchor), isTRUE(x$point_valid), "
                        "identical(x$objective_source, 'fitted_model_par'), "
                        "identical(x$total_nll, 100))"
                    ),
                    str(anchor / "profile_point_info.rds"),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            )

    def test_valid_fitted_scalar_100_anchor_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, base_model = self.make_case(root, "profile")
            unit_model = input_root / "4001/outputs/checks/profile/model"
            self.write_profile_point(
                unit_model,
                100,
                100,
                source="fitted_model_par",
                valid=True,
                par_text="base final.par\n",
            )
            self.write_compact_base_payload(base_model, "different base par\n")

            self.run_merge(
                input_root,
                output_dir,
                "profile",
                extra_env={
                    **self.mock_env(),
                    "PROFILE_INCLUDE_BASE_ANCHOR": "true",
                    "PROFILE_EXPECTED_VALUES": "100",
                    "PROFILE_POST_MERGE_REPAIR": "false",
                },
            )

            anchor = output_dir / "models/model/profile/adult_biomass/scalar_100"
            self.assertEqual(
                (anchor / "final.par").read_text(encoding="utf-8"),
                "base final.par\n",
            )
            subprocess.run(
                [
                    "Rscript",
                    "-e",
                    (
                        "x <- readRDS(commandArgs(TRUE)[1]); "
                        "stopifnot(identical(x$total_nll, 100))"
                    ),
                    str(anchor / "profile_point_info.rds"),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            )

    def test_absolute_fitted_anchor_uses_the_fitted_quantity_directly(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, base_model = self.make_case(root, "profile")
            self.write_compact_base_payload(base_model, "base final.par\n")
            center = "2677499"

            self.run_merge(
                input_root,
                output_dir,
                "profile",
                extra_env={
                    **self.mock_env(),
                    "PROFILE_VALUE_MODE": "absolute",
                    "PROFILE_TARGET_VALUES": f"2500000 {center} 2800000",
                    "PROFILE_TARGET_CENTER": center,
                    "PROFILE_CENTER": center,
                    "PROFILE_EXPECTED_VALUES": f"2500000 {center} 2800000",
                    "PROFILE_BASE_QUANTITY": center,
                    "PROFILE_INCLUDE_BASE_ANCHOR": "true",
                    "PROFILE_POST_MERGE_REPAIR": "false",
                },
            )

            anchor_files = list(
                (output_dir / "models/model/profile").glob(
                    f"*/scalar_{center}/profile_point_info.rds"
                )
            )
            self.assertEqual(len(anchor_files), 1)
            result = subprocess.run(
                [
                    "Rscript", "-e",
                    (
                        "x <- readRDS(commandArgs(TRUE)[1]); "
                        "print(list(scalar=x$scalar, target=x$target_quantity, "
                        "percent=x$row$scalar_is_percent[[1]], "
                        "attained=x$target_attained, valid=x$point_valid)); "
                        "stopifnot(as.numeric(x$scalar) == 2677499, "
                        "as.numeric(x$target_quantity) == 2677499, "
                        "!isTRUE(x$row$scalar_is_percent[[1]]), "
                        "isTRUE(x$target_attained), isTRUE(x$point_valid))"
                    ),
                    str(anchor_files[0]),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unresolved_post_merge_closure_is_blocking(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, base_model = self.make_case(root, "profile")
            self.write_compact_base_payload(base_model, "base final.par\n")

            self.run_merge(
                input_root,
                output_dir,
                "profile",
                extra_env={
                    **self.mock_env(),
                    "PROFILE_INCLUDE_BASE_ANCHOR": "true",
                    "PROFILE_EXPECTED_VALUES": "90 100",
                    "CHECK_SMOKE_ONLY": "false",
                    "MFK_MOCK_STOP_REASON": "no_improvement",
                    "MFK_MOCK_SUSPECT_SCALARS": "90",
                },
            )

            published = output_dir / "models/model/profile"
            diagnostics = read_csv(published / "profile-merge-diagnostics.csv")
            closure = [row for row in diagnostics if row["code"] == "profile_closure_incomplete"]
            self.assertEqual(len(closure), 1)
            self.assertEqual(closure[0]["level"], "critical")
            self.assertEqual(closure[0]["blocking"], "TRUE")
            summary = read_csv(published / "check-summary.csv")[0]
            self.assertEqual(summary["merge_status"], "incomplete")

    def test_unresolved_profile_structure_is_critical_and_blocking(self):
        cases = (
            (False, {"missing_fitted_profile_anchor"}),
            (
                True,
                {
                    "off_center_nll_below_fitted_anchor",
                    "remaining_profile_spike",
                },
            ),
        )
        for include_anchor, expected_codes in cases:
            with self.subTest(include_anchor=include_anchor), tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                input_root, output_dir, base_model = self.make_case(root, "profile")
                unit_model = input_root / "4001/outputs/checks/profile/model"
                if include_anchor:
                    self.write_compact_base_payload(base_model, "base fitted par\n")
                    self.write_profile_point(unit_model, 80, 120)
                    self.write_profile_point(unit_model, 90, 80)
                    self.write_profile_point(unit_model, 110, 120)
                    expected_values = "80 90 100 110"
                else:
                    self.write_profile_point(unit_model, 90, 101)
                    expected_values = "90"

                self.run_merge(
                    input_root,
                    output_dir,
                    "profile",
                    extra_env={
                        **self.mock_env(),
                        "CHECK_SMOKE_ONLY": "false",
                        "PROFILE_INCLUDE_BASE_ANCHOR": (
                            "true" if include_anchor else "false"
                        ),
                        "PROFILE_EXPECTED_VALUES": expected_values,
                        "PROFILE_POST_MERGE_REPAIR": "false",
                    },
                )

                published = output_dir / "models/model/profile"
                diagnostics = read_csv(
                    published / "profile-merge-diagnostics.csv"
                )
                rows = [row for row in diagnostics if row["code"] in expected_codes]
                self.assertEqual({row["code"] for row in rows}, expected_codes)
                self.assertTrue(all(row["level"] == "critical" for row in rows))
                self.assertTrue(all(row["blocking"] == "TRUE" for row in rows))
                summary = read_csv(published / "check-summary.csv")[0]
                self.assertEqual(summary["profile_diagnostic_status"], "critical")
                self.assertEqual(summary["profile_diagnostics_blocking"], "TRUE")
                self.assertEqual(summary["merge_status"], "incomplete")
                self.assertTrue((output_dir / "models/model/model_payload.rds").is_file())

    def test_profile_closure_defaults_and_env_are_wired_to_standalone_api(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            input_root, output_dir, _ = self.make_case(root, "profile")
            call_file = root / "closure-call.rds"

            self.run_merge(
                input_root,
                output_dir,
                "profile",
                extra_env={
                    **self.mock_env(),
                    "MFK_MOCK_CALL_FILE": str(call_file),
                    "PROFILE_NAME": "adult_biomass",
                    "PROFILE_CONVERGENCE_EXPONENT": "-3",
                    "PROFILE_JAGGED_TOLERANCE": "0.25",
                    "PROFILE_JAGGED_REPAIR_PASSES": "3",
                    "PROFILE_MAX_JAGGED_REPAIRS": "4",
                    "PROFILE_REPAIR_CPUS": "7",
                    "PROFILE_HBASE_REPAIR_CPUS": "2",
                    "PROFILE_HBASE_REPAIR_MEMORY_GB": "30",
                    "PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB": "5",
                },
            )

            self.assertTrue(call_file.is_file())
            subprocess.run(
                [
                    "Rscript",
                    "-e",
                    (
                        "x <- readRDS(commandArgs(TRUE)[1]); "
                        "stopifnot(isTRUE(all.equal(x$search_threshold, 1e-3)), "
                        "isTRUE(x$final_polish), "
                        "isTRUE(x$parallel), "
                        "isTRUE(all.equal(x$polish_threshold, 1e-4)), "
                        "isTRUE(all.equal(x$jagged_tolerance, 0.25)), "
                        "identical(x$repair_passes, 3L), "
                        "identical(x$max_scalars, 4L), "
                        "identical(x$max_runs, 20L), "
                        "identical(x$cpus, 7L), "
                        "isTRUE(all.equal(x$memory_gb, 30)), "
                        "isTRUE(all.equal(x$memory_gb_per_worker, 5)))"
                    ),
                    str(call_file),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            )
            published = output_dir / "models/model/profile"
            result_files = list(published.rglob("profile-closure-result.rds"))
            audit_files = list(
                published.rglob("quantity-profile-closure-audit.rds")
            )
            self.assertEqual(len(result_files), 1)
            self.assertEqual(len(audit_files), 1)
            subprocess.run(
                [
                    "Rscript",
                    "-e",
                    (
                        "x <- readRDS(commandArgs(TRUE)[1]); "
                        "stopifnot(identical(x$stop_reason, 'clean_profile'), "
                        "length(x$attempted_scalars) == 0L)"
                    ),
                    str(result_files[0]),
                ],
                cwd=ROOT,
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
