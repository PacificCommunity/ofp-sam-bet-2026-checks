source("R/model_output_adapter.R")

message("[checks] preparing MFCL run bundle input")
prepared <- prepare_model_for_check()

output_dir <- env("OUTPUT_DIR", "outputs")
work_dir <- env("WORK_DIR", "work")
program_path <- env("PROGRAM_PATH", prepared$program_path)
if (!nzchar(program_path)) program_path <- prepared$program_path
if (!nzchar(program_path)) program_path <- "/home/mfcl/mfclo64"

model_key <- gsub("[^A-Za-z0-9_.-]+", "_", prepared$model_key)
if (!nzchar(model_key)) model_key <- "model"

bundle_name <- env("BUNDLE_NAME", paste0(model_key, "-mfcl-run-bundle"))
bundle_name <- gsub("[^A-Za-z0-9_.-]+", "_", bundle_name)
if (!nzchar(bundle_name)) bundle_name <- paste0(model_key, "-mfcl-run-bundle")

final_par_name <- env("BUNDLE_FINAL_PAR_NAME", "11.par")
final_par_name <- basename(final_par_name)
if (!nzchar(final_par_name)) final_par_name <- "11.par"

report_output_par <- env("BUNDLE_REPORT_OUTPUT_PAR", "report.par")
report_output_par <- basename(report_output_par)
if (!nzchar(report_output_par)) report_output_par <- "report.par"

include_exe <- truthy(env("BUNDLE_INCLUDE_EXE", "true"), TRUE)
verify_zip_run <- truthy(env("BUNDLE_VERIFY_ZIP_RUN", "true"), TRUE)
exe_name <- basename(env("BUNDLE_EXE_NAME", basename(program_path)))
exe_name <- gsub("[^A-Za-z0-9_.-]+", "_", exe_name)
if (!nzchar(exe_name)) exe_name <- "mfclo64"

run_dir <- file.path(work_dir, "bundle-run", model_key)
bundle_dir <- file.path(output_dir, "model-bundles", model_key)
bundle_root <- file.path(bundle_dir, bundle_name)
dir.create(bundle_dir, recursive = TRUE, showWarnings = FALSE)
invisible(copy_dir(prepared$case_dir, run_dir))

final_source <- prepared$start_par
if (!file.exists(final_source)) {
  fallback <- latest_par(run_dir)
  if (nzchar(fallback) && file.exists(fallback)) final_source <- fallback
}
if (!file.exists(final_source)) {
  stop("Could not find a fitted par to bundle for ", model_key, call. = FALSE)
}
final_target <- file.path(run_dir, final_par_name)
if (!identical(normalize_loose(final_source), normalize_loose(final_target))) {
  ok <- file.copy(final_source, final_target, overwrite = TRUE, copy.date = TRUE)
  if (!isTRUE(ok)) {
    stop("Could not copy fitted par to ", final_par_name, call. = FALSE)
  }
}

frq_name <- env("BUNDLE_FRQ", basename(prepared$frq))
frq_name <- basename(frq_name)
if (!nzchar(frq_name) || !file.exists(file.path(run_dir, frq_name))) {
  frq <- latest_file(case_files(run_dir, "[.]frq$"))
  frq_name <- basename(frq)
}
if (!nzchar(frq_name) || !file.exists(file.path(run_dir, frq_name))) {
  stop("Bundled model case has no .frq file.", call. = FALSE)
}

bundled_exe <- ""
if (isTRUE(include_exe)) {
  if (!file.exists(program_path)) {
    stop("BUNDLE_INCLUDE_EXE=true but PROGRAM_PATH does not exist: ", program_path, call. = FALSE)
  }
  bundled_exe <- file.path(run_dir, exe_name)
  ok <- file.copy(program_path, bundled_exe, overwrite = TRUE, copy.mode = TRUE, copy.date = TRUE)
  if (!isTRUE(ok) || !file.exists(bundled_exe)) {
    stop("Could not copy MFCL executable into bundle: ", program_path, call. = FALSE)
  }
  Sys.chmod(bundled_exe, mode = "0755")
}

report_status <- NA_integer_
report_command <- ""
report_log <- file.path(run_dir, "bundle-report.log")
generated_plot_rep <- ""
generated_rep <- ""
default_report_switches <- "-switch 6 1 1 1 1 189 1 1 190 1 1 188 1 1 187 1 1 186 0"
report_switch_text <- env("BUNDLE_REPORT_SWITCHES", default_report_switches)
report_switch_tokens <- split_values(report_switch_text)
if (!length(report_switch_tokens)) report_switch_tokens <- split_values(default_report_switches)
if (truthy(env("BUNDLE_GENERATE_REPORTS", "true"), TRUE)) {
  args <- c(frq_name, final_par_name, report_output_par, report_switch_tokens)
  report_command <- paste(c(program_path, args), collapse = " ")
  message("[checks] regenerating MFCL report files: ", report_command)
  old <- setwd(run_dir)
  on.exit(setwd(old), add = TRUE)
  report_status <- system2(program_path, args, stdout = report_log, stderr = report_log)
  setwd(old)
  if (!identical(as.integer(report_status), 0L) &&
      !truthy(env("BUNDLE_ALLOW_REPORT_FAILURE", "false"), FALSE)) {
    stop(
      "MFCL report regeneration failed with status ", report_status,
      "; see ", report_log,
      call. = FALSE
    )
  }
}

plot_reps <- list.files(run_dir, pattern = "^plot.*[.]rep$", full.names = TRUE, ignore.case = TRUE)
all_reps <- list.files(run_dir, pattern = "[.]rep$", full.names = TRUE, ignore.case = TRUE)
generated_plot_rep <- latest_file(plot_reps)
generated_rep <- latest_file(all_reps)
if (nzchar(generated_plot_rep)) {
  file.copy(generated_plot_rep, file.path(run_dir, "plot.rep"), overwrite = TRUE, copy.date = TRUE)
} else if (nzchar(generated_rep)) {
  file.copy(generated_rep, file.path(run_dir, "plot.rep"), overwrite = TRUE, copy.date = TRUE)
}
if (!file.exists(file.path(run_dir, "plot.rep")) &&
    truthy(env("BUNDLE_REQUIRE_PLOT_REP", "true"), TRUE)) {
  stop("MFCL report regeneration did not produce a plot .rep file.", call. = FALSE)
}

script_program_default <- if (nzchar(bundled_exe)) paste0("./", exe_name) else "mfclo64"
plot_script <- c(
  "#!/usr/bin/env bash",
  "set -euo pipefail",
  "cd \"$(dirname \"${BASH_SOURCE[0]}\")\"",
  paste0("PROGRAM_PATH=\"${PROGRAM_PATH:-", script_program_default, "}\""),
  paste(
    "\"${PROGRAM_PATH}\"",
    shQuote(frq_name),
    shQuote(final_par_name),
    shQuote(report_output_par),
    paste(shQuote(report_switch_tokens), collapse = " ")
  ),
  "latest_rep=\"$(find . -maxdepth 1 -type f \\( -iname 'plot*.rep' -o -iname '*.rep' \\) -printf '%T@ %p\\n' | sort -nr | awk 'NR == 1 {sub(/^[^ ]+ /, \"\"); sub(/^\\.\\//, \"\"); print}')\"",
  "if [[ -n \"${latest_rep}\" && \"${latest_rep}\" != \"plot.rep\" ]]; then",
  "  cp -p \"${latest_rep}\" plot.rep",
  "fi"
)
writeLines(plot_script, file.path(run_dir, "make-plot-rep.sh"))
Sys.chmod(file.path(run_dir, "make-plot-rep.sh"), mode = "0755")

doitall_present <- file.exists(file.path(run_dir, "doitall.sh"))
if (isTRUE(doitall_present)) {
  Sys.chmod(file.path(run_dir, "doitall.sh"), mode = "0755")
  doitall_wrapper <- c(
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "cd \"$(dirname \"${BASH_SOURCE[0]}\")\"",
    paste0("export PROGRAM_PATH=\"${PROGRAM_PATH:-", script_program_default, "}\""),
    "exec ./doitall.sh \"$@\""
  )
  writeLines(doitall_wrapper, file.path(run_dir, "run-doitall.sh"))
  Sys.chmod(file.path(run_dir, "run-doitall.sh"), mode = "0755")
}

readme <- c(
  paste0("# MFCL Run Bundle: ", model_key),
  "",
  "This directory is intended to be runnable outside Kflow.",
  "",
  "Key files:",
  paste0("- `", final_par_name, "`: fitted final par restored from the selected Kflow model output."),
  if (nzchar(bundled_exe)) paste0("- `", exe_name, "`: MFCL executable copied from the Kflow runtime image.") else NULL,
  "- `plot.rep`: convenience copy of the latest regenerated plot report.",
  paste0("- `make-plot-rep.sh`: regenerates report files directly from `", final_par_name, "`."),
  "- `doitall.sh`: source model run script when present; it is for a full rerun and may recreate the final par.",
  if (isTRUE(doitall_present)) "- `run-doitall.sh`: wrapper that runs `doitall.sh` with the bundled MFCL executable." else NULL,
  "- `bundle-report.log`: log from regenerating report files.",
  "",
  "To regenerate reports from the fitted par:",
  "",
  "```sh",
  "./make-plot-rep.sh",
  "```",
  "",
  "To rerun the full model from the original starting files:",
  "",
  "```sh",
  "./run-doitall.sh",
  "```"
)
writeLines(readme, file.path(run_dir, "README-bundle.md"))

manifest <- data.frame(
  schema = "ofp-sam.checks.mfcl-run-bundle.v1",
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  model_key = model_key,
  model_selector = env("MODEL_SELECTOR", ""),
  input_root = default_input_root(),
  compact_dir = as.character(prepared$manifest$compact_dir[[1L]] %||% ""),
  source_case = as.character(prepared$manifest$source_case[[1L]] %||% ""),
  source_repo = env("MODEL_SOURCE_REPO", ""),
  source_ref = env("MODEL_SOURCE_REF", ""),
  frq = frq_name,
  final_par = final_par_name,
  final_par_source = normalize_loose(final_source),
  report_output_par = report_output_par,
  plot_rep = if (file.exists(file.path(run_dir, "plot.rep"))) "plot.rep" else "",
  generated_plot_rep = if (nzchar(generated_plot_rep)) basename(generated_plot_rep) else "",
  generated_rep = if (nzchar(generated_rep)) basename(generated_rep) else "",
  report_status = suppressWarnings(as.integer(report_status)),
  report_command = report_command,
  program_path = program_path,
  bundled_exe = if (nzchar(bundled_exe)) exe_name else "",
  bundled_exe_size = if (nzchar(bundled_exe) && file.exists(bundled_exe)) file.info(bundled_exe)$size else NA_real_,
  bundled_exe_md5 = if (nzchar(bundled_exe) && file.exists(bundled_exe)) unname(tools::md5sum(bundled_exe)) else "",
  doitall = if (isTRUE(doitall_present)) "doitall.sh" else "",
  doitall_wrapper = if (isTRUE(doitall_present)) "run-doitall.sh" else "",
  stringsAsFactors = FALSE
)
write.csv(manifest, file.path(run_dir, "bundle-manifest.csv"), row.names = FALSE)
saveRDS(as.list(manifest), file.path(run_dir, "bundle-manifest.rds"), compress = "xz")

invisible(copy_dir(run_dir, bundle_root))

zip_file <- file.path(bundle_dir, paste0(bundle_name, ".zip"))
unlink(zip_file, force = TRUE)
old <- setwd(bundle_dir)
on.exit(setwd(old), add = TRUE)
zip_status <- system2("zip", c("-r", "-q", basename(zip_file), basename(bundle_root)))
setwd(old)
if (!identical(as.integer(zip_status), 0L) || !file.exists(zip_file)) {
  stop("Could not create zip bundle: ", zip_file, call. = FALSE)
}

verification <- data.frame(
  schema = "ofp-sam.checks.mfcl-run-bundle-verification.v1",
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  model_key = model_key,
  bundle_zip = normalize_loose(zip_file),
  zip_run_status = NA_integer_,
  plot_rep = "",
  plot_rep_size = NA_real_,
  command = "",
  log = "",
  stringsAsFactors = FALSE
)
if (isTRUE(verify_zip_run)) {
  if (!nzchar(bundled_exe)) {
    stop("BUNDLE_VERIFY_ZIP_RUN=true requires BUNDLE_INCLUDE_EXE=true.", call. = FALSE)
  }
  verify_dir <- file.path(work_dir, "bundle-verify", model_key)
  unlink(verify_dir, recursive = TRUE, force = TRUE)
  dir.create(verify_dir, recursive = TRUE, showWarnings = FALSE)
  verify_log <- file.path(bundle_dir, "bundle-verify.log")
  unzip_bin <- Sys.which("unzip")
  if (nzchar(unzip_bin)) {
    unzip_status <- system2(unzip_bin, c("-q", normalize_loose(zip_file), "-d", normalize_loose(verify_dir)))
  } else {
    unzip_status <- tryCatch({
      utils::unzip(zip_file, exdir = verify_dir)
      0L
    }, error = function(e) {
      writeLines(conditionMessage(e), verify_log)
      1L
    })
  }
  if (!identical(as.integer(unzip_status), 0L)) {
    stop("Could not extract zip bundle for verification: ", zip_file, call. = FALSE)
  }
  extracted_root <- file.path(verify_dir, bundle_name)
  if (!dir.exists(extracted_root)) {
    roots <- list.files(verify_dir, full.names = TRUE, no.. = TRUE)
    roots <- roots[dir.exists(roots)]
    if (length(roots) == 1L) extracted_root <- roots[[1L]]
  }
  if (!dir.exists(extracted_root)) {
    stop("Zip verification could not find extracted bundle root.", call. = FALSE)
  }
  extracted_exe <- file.path(extracted_root, exe_name)
  if (!file.exists(extracted_exe)) {
    stop("Zip verification could not find bundled executable: ", exe_name, call. = FALSE)
  }
  Sys.chmod(extracted_exe, mode = "0755")
  unlink(file.path(extracted_root, c("plot.rep", paste0("plot-", report_output_par, ".rep"))), force = TRUE)
  verify_command <- paste("bash ./make-plot-rep.sh")
  message("[checks] verifying extracted bundle with bundled executable: ", verify_command)
  old <- setwd(extracted_root)
  on.exit(setwd(old), add = TRUE)
  verify_status <- system2("bash", "./make-plot-rep.sh", stdout = verify_log, stderr = verify_log)
  setwd(old)
  verification$zip_run_status <- suppressWarnings(as.integer(verify_status))
  verification$plot_rep <- if (file.exists(file.path(extracted_root, "plot.rep"))) "plot.rep" else ""
  verification$plot_rep_size <- if (nzchar(verification$plot_rep[[1L]])) file.info(file.path(extracted_root, "plot.rep"))$size else NA_real_
  verification$command <- verify_command
  verification$log <- normalize_loose(verify_log)
  if (!identical(as.integer(verify_status), 0L)) {
    stop("Extracted bundle verification failed with status ", verify_status, "; see ", verify_log, call. = FALSE)
  }
  if (!nzchar(verification$plot_rep[[1L]]) || !is.finite(verification$plot_rep_size[[1L]]) ||
      verification$plot_rep_size[[1L]] <= 0) {
    stop("Extracted bundle verification did not regenerate plot.rep.", call. = FALSE)
  }
}
write.csv(verification, file.path(bundle_dir, "bundle-verification.csv"), row.names = FALSE)

index <- data.frame(
  schema = manifest$schema[[1L]],
  created_at = manifest$created_at[[1L]],
  model_key = model_key,
  model_selector = manifest$model_selector[[1L]],
  bundle_dir = normalize_loose(bundle_root),
  bundle_zip = normalize_loose(zip_file),
  bundle_zip_relative = file.path("model-bundles", model_key, basename(zip_file)),
  final_par = final_par_name,
  plot_rep = manifest$plot_rep[[1L]],
  report_status = manifest$report_status[[1L]],
  bundled_exe = manifest$bundled_exe[[1L]],
  zip_run_status = verification$zip_run_status[[1L]],
  stringsAsFactors = FALSE
)
write.csv(index, file.path(bundle_dir, "bundle-index.csv"), row.names = FALSE)
write.csv(index, file.path(output_dir, "model-bundle-index.csv"), row.names = FALSE)

message("[checks] wrote MFCL run bundle: ", normalize_loose(zip_file))
