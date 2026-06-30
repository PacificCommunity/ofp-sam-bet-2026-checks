args <- commandArgs(trailingOnly = TRUE)
check_type <- if (length(args) && nzchar(args[[1L]])) args[[1L]] else Sys.getenv("CHECK_TYPE", "jitter")
check_type <- tolower(check_type)

source("R/model_output_adapter.R")
suppressPackageStartupMessages(library(mfclkit))

message("[checks] preparing model input")
prepared <- prepare_model_for_check()

program_path <- env("PROGRAM_PATH", prepared$program_path)
if (!nzchar(program_path)) program_path <- prepared$program_path
if (!nzchar(program_path)) program_path <- "/home/mfcl/mfclo64"

backend <- mfk_native_backend(program_path = program_path)
output_dir <- env("OUTPUT_DIR", "outputs")
model_key <- gsub("[^A-Za-z0-9_.-]+", "_", prepared$model_key)
if (!nzchar(model_key)) model_key <- "model"
model_dir <- file.path(output_dir, "checks", check_type, model_key)
dir.create(model_dir, recursive = TRUE, showWarnings = FALSE)

program_token <- basename(program_path)
frq_name <- basename(prepared$frq)
start_par_name <- basename(prepared$start_par)

mfcl_command <- function(input_par = start_par_name, output_par = "check.par", extra = character()) {
  c(program_token, frq_name, input_par, output_par, extra)
}

check_final_phase_command <- function(script_name = "jitter.final.sh") {
  out <- file.path(prepared$case_dir, script_name)
  lines <- c(
    "#!/bin/sh",
    "set -eu",
    "",
    "program_path=${PROGRAM_PATH:-mfclo64}",
    "max_evals=${BET_JITTER_MAX_EVALS:-5000}",
    "phase10_11_convergence=${BET_PHASE10_11_CONVERGENCE:--3}",
    "echo \"[checks] jitter final phase max evals: $max_evals\"",
    "echo \"[checks] jitter final phase convergence criterion: $phase10_11_convergence\"",
    "",
    "$program_path bet.frq 00.par jitter.par -file - <<JITTER_FINAL",
    "  1 1 $max_evals",
    "  1 50 $phase10_11_convergence",
    "  1 190 1",
    "  1 246 1",
    "JITTER_FINAL"
  )
  writeLines(lines, out)
  Sys.chmod(out, mode = "0755")
  c("sh", script_name)
}

default_jitter_slots <- function() {
  c(
    "rep_rate_dev_coffs",
    "rel_rec",
    "tot_pop",
    "tot_pop_implicit",
    "rec_standard",
    "rec_orthogonal",
    "orth_coffs",
    "new_orth_coffs",
    "annual_rel_rec_coffs",
    "region_pars",
    "availability_coffs",
    "av_q_coffs",
    "ini_q_coffs",
    "q_dev_coffs",
    "effort_dev_coffs",
    "catch_dev_coffs",
    "sel_dev_corr",
    "sel_dev_coffs",
    "sel_dev_coffs2",
    "season_q_pars",
    "fm_level_regression_pars"
  )
}

check_jitter_slots <- function() {
  slots <- split_values(env("JITTER_SLOTS", ""))
  if (length(slots)) slots else default_jitter_slots()
}

resolve_selftest_runner <- function(runner) {
  if (!nzchar(runner)) runner <- env("CHECK_SELFTEST_SCRIPT", "")
  if (!nzchar(runner)) return("")
  if (file.exists(runner)) {
    out <- normalize_loose(runner)
    runner_work_dir <- env("SELFTEST_RUNNER_WORK_DIR", env("CHECK_SELFTEST_WORK_DIR", ""))
    if (nzchar(runner_work_dir)) attr(out, "runner_work_dir") <- normalize_loose(runner_work_dir)
    return(out)
  }
  repo <- env("SELFTEST_RUNNER_REPO", env("CHECK_SELFTEST_REPO", ""))
  if (!nzchar(repo)) return(runner)
  ref <- env("SELFTEST_RUNNER_REF", env("CHECK_SELFTEST_REF", "main"))
  runner_root <- env("SELFTEST_RUNNER_ROOT", env("CHECK_SELFTEST_ROOT", ""))
  if (!nzchar(runner_root)) {
    runner_root <- git_clone_repo(repo, ref, file.path(env("WORK_DIR", "work"), "selftest-runner-source"))
  }
  candidate <- if (is_absolute_path(runner)) runner else file.path(runner_root, runner)
  if (file.exists(candidate)) {
    out <- normalize_loose(candidate)
    attr(out, "runner_work_dir") <- normalize_loose(env("SELFTEST_RUNNER_WORK_DIR", env("CHECK_SELFTEST_WORK_DIR", runner_root)))
    out
  } else {
    runner
  }
}

copy_if_exists <- function(from, to_dir, to_name = basename(from)) {
  if (!file.exists(from)) return(FALSE)
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  isTRUE(file.copy(from, file.path(to_dir, to_name), overwrite = TRUE, copy.date = TRUE))
}

profile_input_par <- function(chain_start_par = NULL) {
  if (!is.null(chain_start_par) &&
      length(chain_start_par) &&
      !is.na(chain_start_par[[1L]]) &&
      nzchar(as.character(chain_start_par[[1L]]))) {
    basename(as.character(chain_start_par[[1L]]))
  } else {
    start_par_name
  }
}

aspm_extra_switch_lines <- function() {
  raw <- env("ASPM_EXTRA_SWITCH_LINES", "")
  if (!nzchar(raw)) return(character())
  lines <- unlist(strsplit(raw, "\\r?\\n|;", perl = TRUE), use.names = FALSE)
  lines <- trimws(lines)
  lines[nzchar(lines)]
}

relative_to <- function(path, root = output_dir) {
  path <- normalize_loose(path)
  root <- normalize_loose(root)
  prefix <- paste0(root, "/")
  if (identical(path, root)) return(".")
  if (startsWith(path, prefix)) substring(path, nchar(prefix) + 1L) else path
}

df_value <- function(df, name, i, default = "") {
  if (!is.data.frame(df) || !name %in% names(df) || i > nrow(df)) return(default)
  df[[name]][[i]] %||% default
}

check_model_index_row <- function() {
  compact_dir <- as.character(prepared$manifest$compact_dir[[1L]] %||% "")
  row <- prepared$row
  data.frame(
    check_type = check_type,
    model_key = model_key,
    parent_model_key = model_key,
    model_label = as.character(row$model_label %||% model_key),
    step_id = as.character(row$step_id %||% model_key),
    model_dir = basename(model_dir),
    model_folder = basename(model_dir),
    check_model_dir = normalize_loose(model_dir),
    check_model_relative_dir = relative_to(model_dir),
    model_source = as.character(row$model_source %||% ""),
    input_compact_dir = compact_dir,
    payload_role = "check_model_root",
    stringsAsFactors = FALSE
  )
}

write_check_model_indices <- function(index) {
  model_root <- dirname(model_dir)
  write.csv(index, file.path(model_root, "model-index.csv"), row.names = FALSE)
  write.csv(index, file.path(model_root, "check-model-index.csv"), row.names = FALSE)
  write.csv(index, file.path(output_dir, "checks-index.csv"), row.names = FALSE)
  invisible(index)
}

payload_text <- function(x, default = "") {
  value <- tryCatch(as.character(x), error = function(e) character())
  if (!length(value) || is.na(value[[1L]]) || !nzchar(value[[1L]])) default else value[[1L]]
}

payload_number <- function(x) {
  value <- suppressWarnings(as.numeric(x))
  if (!length(value) || !is.finite(value[[1L]])) NA_real_ else value[[1L]]
}

write_basic_payload_manifest <- function(payload, folder, payload_file) {
  info <- tryCatch(payload$data$info, error = function(e) NULL)
  registry <- tryCatch(info$registry, error = function(e) NULL)
  model_label <- payload_text(tryCatch(registry$plot_label, error = function(e) NULL),
    payload_text(tryCatch(registry$model_label, error = function(e) NULL),
      payload_text(tryCatch(registry$model_token, error = function(e) NULL),
        payload_text(tryCatch(info$plot_label, error = function(e) NULL),
          payload_text(tryCatch(info$model_label, error = function(e) NULL),
            payload_text(tryCatch(info$model_token, error = function(e) NULL), basename(folder))
          )
        )
      )
    )
  )
  manifest <- data.frame(
    schema = "mfclshiny.model_payload_manifest.v1",
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    model_label = model_label,
    model_folder = normalize_loose(folder),
    payload_file = normalize_loose(payload_file),
    payload_bytes = suppressWarnings(as.numeric(file.info(payload_file)$size)),
    obj_fun = payload_number(tryCatch(payload$obj_fun, error = function(e) NA_real_)),
    max_grad = payload_number(tryCatch(payload$max_grad, error = function(e) NA_real_)),
    has_par = !is.null(tryCatch(payload$data$ParOut, error = function(e) NULL)),
    has_rep = !is.null(tryCatch(payload$data$RepOut, error = function(e) NULL)),
    has_lf = !is.null(tryCatch(payload$data$LengOut, error = function(e) NULL)),
    has_wf = !is.null(tryCatch(payload$data$WeightOut, error = function(e) NULL)),
    has_tags = !is.null(tryCatch(payload$data$TagOut, error = function(e) NULL)) ||
      !is.null(tryCatch(payload$data$TagTempOut, error = function(e) NULL)),
    has_caal = !is.null(tryCatch(payload$data$AgeOut, error = function(e) NULL)),
    has_diagnostics = !is.null(tryCatch(payload$data$Diagnostics, error = function(e) NULL)),
    stringsAsFactors = FALSE
  )
  write.csv(manifest, file.path(folder, "model_payload_manifest.csv"), row.names = FALSE)
  if (requireNamespace("jsonlite", quietly = TRUE)) {
    jsonlite::write_json(
      manifest,
      file.path(folder, "model_payload_manifest.json"),
      dataframe = "rows",
      auto_unbox = TRUE,
      pretty = TRUE,
      null = "null"
    )
  }
  invisible(manifest)
}

augment_base_payload_manifest <- function(index) {
  base_payload <- file.path(model_dir, "model_payload.rds")
  csv_file <- file.path(model_dir, "model_payload_manifest.csv")
  json_file <- file.path(model_dir, "model_payload_manifest.json")
  if (file.exists(base_payload) && !file.exists(csv_file) && !file.exists(json_file)) {
    payload <- tryCatch(readRDS(base_payload), error = function(e) NULL)
    if (!is.null(payload)) {
      err <- tryCatch({
        write_basic_payload_manifest(payload = payload, folder = model_dir, payload_file = base_payload)
        NULL
      }, error = function(e) e)
      if (!is.null(err)) {
        warning("base payload manifest build failed: ", conditionMessage(err), call. = FALSE)
      }
    }
  }
  manifest <- NULL
  if (file.exists(csv_file)) {
    manifest <- tryCatch(read.csv(csv_file, stringsAsFactors = FALSE), error = function(e) NULL)
  }
  if (is.null(manifest) && file.exists(json_file) && requireNamespace("jsonlite", quietly = TRUE)) {
    manifest <- tryCatch(as.data.frame(jsonlite::read_json(json_file, simplifyVector = TRUE), stringsAsFactors = FALSE), error = function(e) NULL)
  }
  if (is.null(manifest) || !nrow(manifest)) return(invisible(NULL))

  manifest$payload_role <- "base_model"
  manifest$check_type <- check_type
  manifest$parent_model_key <- model_key
  manifest$check_model_dir <- normalize_loose(model_dir)
  manifest$check_model_relative_dir <- relative_to(model_dir)
  for (name in intersect(names(index), c("model_label", "step_id", "model_source", "input_compact_dir"))) {
    manifest[[paste0("source_", name)]] <- as.character(index[[name]][[1L]])
  }
  write.csv(manifest, csv_file, row.names = FALSE)
  if (requireNamespace("jsonlite", quietly = TRUE)) {
    jsonlite::write_json(manifest, json_file, dataframe = "rows", auto_unbox = TRUE, pretty = TRUE, null = "null")
  }
  invisible(manifest)
}

stage_report_model_payload <- function() {
  compact_dir <- as.character(prepared$manifest$compact_dir[[1L]] %||% "")
  for (name in c(
    "model_payload.rds", "model_payload_manifest.json", "model_payload_manifest.csv",
    "fishery_map.R", "tag_rep_map.R", "bet.region_map.geojson", "bet.reg_scaling"
  )) {
    copy_if_exists(file.path(compact_dir, name), model_dir)
  }
  copy_if_exists(prepared$start_par, model_dir, basename(prepared$start_par))

  index <- check_model_index_row()
  write_check_model_indices(index)
  augment_base_payload_manifest(index)
  invisible(index)
}

stage_hessian_stitch_inputs <- function() {
  patterns <- c(
    "[.]frq$",
    "[.]ini$",
    "[.]tag$",
    "[.]age_length$",
    "[.]dep$",
    "[.]dp2$",
    "^mfcl[.]cfg$",
    "^depgrad[.]rpt$",
    "^Hess[.]rpt$"
  )
  files <- unique(unlist(lapply(patterns, function(pattern) {
    list.files(prepared$case_dir, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
  }), use.names = FALSE))
  copied <- vapply(files, copy_if_exists, logical(1), to_dir = model_dir)
  names(copied) <- basename(files)
  copied
}

write_check_payload_index <- function(payload_index = data.frame()) {
  check_index <- check_model_index_row()
  rows <- list()
  base_payload <- file.path(model_dir, "model_payload.rds")
  if (file.exists(base_payload)) {
    rows[[length(rows) + 1L]] <- data.frame(
      check_type = check_type,
      parent_model_key = model_key,
      model_label = check_index$model_label[[1L]],
      payload_role = "base_model",
      payload_folder = normalize_loose(model_dir),
      payload_relative_folder = relative_to(model_dir),
      payload_file = normalize_loose(base_payload),
      payload_relative_file = relative_to(base_payload),
      manifest_file = normalize_loose(file.path(model_dir, "model_payload_manifest.json")),
      stringsAsFactors = FALSE
    )
  }
  if (is.data.frame(payload_index) && nrow(payload_index)) {
    for (i in seq_len(nrow(payload_index))) {
      folder <- as.character(df_value(payload_index, "folder", i, ""))
      payload <- as.character(df_value(payload_index, "payload", i, ""))
      if (!nzchar(folder)) next
      if (identical(normalize_loose(folder), normalize_loose(model_dir))) next
      rows[[length(rows) + 1L]] <- data.frame(
        check_type = check_type,
        parent_model_key = model_key,
        model_label = check_index$model_label[[1L]],
        payload_role = "check_output",
        payload_folder = normalize_loose(folder),
        payload_relative_folder = relative_to(folder),
        payload_file = normalize_loose(payload),
        payload_relative_file = relative_to(payload),
        manifest_file = normalize_loose(as.character(df_value(payload_index, "manifest", i, file.path(folder, "model_payload_manifest.json")))),
        payload_ok = isTRUE(df_value(payload_index, "ok", i, FALSE)),
        payload_message = as.character(df_value(payload_index, "message", i, "")),
        stringsAsFactors = FALSE
      )
    }
  }
  out <- bind_rows_fill(rows)
  write.csv(out, file.path(model_dir, "check-payload-index.csv"), row.names = FALSE)
  write.csv(out, file.path(dirname(model_dir), "check-payload-index.csv"), row.names = FALSE)
  invisible(out)
}

check_report_figure_keys <- function() {
  override <- split_values(env("CHECK_REPORT_FIGURE_KEYS", ""))
  if (length(override)) return(override)
  switch(
    check_type,
    jitter = c(
      "figure:jitter-diagnostics",
      "figure:jitter-parameters",
      "figure:jitter-derived-quantities"
    ),
    retro = "figure:retrospective-diagnostics",
    aspm = "figure:aspm-diagnostics",
    selftest = c(
      "figure:selftest-recovery",
      "figure:selftest-simulation",
      "figure:selftest-parameter-recovery"
    ),
    character()
  )
}

write_check_report_selection <- function(output_dir) {
  keys <- check_report_figure_keys()
  if (!length(keys) || !requireNamespace("jsonlite", quietly = TRUE)) {
    return(NULL)
  }
  figure_ids <- sub("^figure:", "", keys)
  labels <- gsub("-", " ", figure_ids, fixed = TRUE)
  labels <- tools::toTitleCase(labels)
  section <- switch(
    check_type,
    jitter = "Jitter",
    retro = "Retro",
    aspm = "ASPM",
    selftest = "Self-test",
    "Checks"
  )
  items <- data.frame(
    item_key = keys,
    type = "figure",
    id = figure_ids,
    label = labels,
    section = section,
    placement = "auto",
    include = TRUE,
    caption = "",
    input_state = "",
    stringsAsFactors = FALSE
  )
  selection <- list(
    schema = "mfclshiny.report_selection.v1",
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    source = paste0("ofp-sam-bet-2026-checks:", check_type),
    analysis = list(),
    inputs = list(),
    items = items
  )
  path <- file.path(output_dir, "check-report-selection.json")
  jsonlite::write_json(selection, path, dataframe = "rows", auto_unbox = TRUE, pretty = TRUE, null = "null")
  write.csv(items, sub("[.]json$", ".csv", path), row.names = FALSE)
  path
}

build_report_payloads <- function() {
  if (!requireNamespace("mfclshiny", quietly = TRUE)) {
    warning("mfclshiny is not installed; skipping report-ready payload build.", call. = FALSE)
    return(invisible(data.frame()))
  }
  payload_index <- tryCatch(
    mfclshiny::build_model_payloads(model_dir, recursive = TRUE, overwrite = TRUE),
    error = function(e) {
      warning("mfclshiny payload build failed: ", conditionMessage(e), call. = FALSE)
      data.frame()
    }
  )
  if (is.data.frame(payload_index)) {
    write.csv(payload_index, file.path(model_dir, "payload-build-index.csv"), row.names = FALSE)
  }
  invisible(payload_index)
}

build_report_ready_figures <- function() {
  if (!truthy(env("CHECK_BUILD_REPORT_FIGURES", "true"), TRUE)) return(invisible(NULL))
  if (!requireNamespace("mfclshiny", quietly = TRUE) ||
      !"build_app_report_figures" %in% getNamespaceExports("mfclshiny")) {
    warning("mfclshiny::build_app_report_figures is not available; skipping report-ready figures.", call. = FALSE)
    return(invisible(NULL))
  }
  out <- file.path(output_dir, "report-ready-checks", check_type, model_key)
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  selection_file <- write_check_report_selection(out)
  result <- tryCatch(
    mfclshiny::build_app_report_figures(
      model_dir = dirname(model_dir),
      folders = model_dir,
      output_dir = out,
      title = paste("BET 2026", check_type, "check figures"),
      formats = "png",
      build_payloads = FALSE,
      overwrite = TRUE,
      render_html = truthy(env("CHECK_RENDER_REVIEW_HTML", "false"), FALSE),
      qmd_file = "check-report.qmd",
      html_file = "check-report.html",
      figure_dir = "figures",
      table_dir = "tables",
      copy_legacy_root = FALSE,
      species_code = env("FLOW_SPECIES", "BET"),
      species_label = env("FLOW_SPECIES_LABEL", "bigeye tuna"),
      assessment_year = env("FLOW_ASSESSMENT_YEAR", "2026"),
      max_fisheries = as.integer(split_numbers(env("PLOT_MAX_FISHERIES", "18"), default = 18)[[1L]]),
      selection_file = selection_file
    ),
    error = function(e) {
      warning("mfclshiny report-ready figure build failed: ", conditionMessage(e), call. = FALSE)
      NULL
    }
  )
  if (!is.null(result) && is.data.frame(result$figures)) {
    write.csv(result$figures, file.path(out, "figure-index.csv"), row.names = FALSE)
  }
  invisible(result)
}

check_compact_outputs_enabled <- function() {
  if (truthy(env("CHECK_KEEP_RAW_OUTPUTS", "false"), FALSE)) return(FALSE)
  truthy(env("CHECK_COMPACT_OUTPUTS", "true"), TRUE)
}

compact_prune_empty_dirs <- function(root) {
  if (!dir.exists(root)) return(invisible(0L))
  dirs <- list.dirs(root, recursive = TRUE, full.names = TRUE)
  dirs <- rev(dirs[nzchar(dirs)])
  removed <- 0L
  for (dir in dirs) {
    if (!dir.exists(dir)) next
    if (length(list.files(dir, all.files = TRUE, no.. = TRUE)) == 0L) {
      unlink(dir, recursive = TRUE, force = TRUE)
      removed <- removed + 1L
    }
  }
  invisible(removed)
}

compact_prune_files <- function(root,
                                keep_names = character(),
                                keep_patterns = character(),
                                recursive = TRUE) {
  if (!dir.exists(root)) return(data.frame())
  files <- list.files(root, all.files = TRUE, no.. = TRUE, recursive = recursive, full.names = TRUE)
  if (!length(files)) return(data.frame())
  info <- file.info(files)
  files <- files[!is.na(info$isdir) & !info$isdir]
  if (!length(files)) return(data.frame())

  rel <- substring(normalize_loose(files), nchar(paste0(normalize_loose(root), "/")) + 1L)
  base <- basename(files)
  keep <- base %in% keep_names | rel %in% keep_names
  if (length(keep_patterns)) {
    keep <- keep | vapply(seq_along(files), function(i) {
      any(grepl(keep_patterns, base[[i]], ignore.case = TRUE)) ||
        any(grepl(keep_patterns, rel[[i]], ignore.case = TRUE))
    }, logical(1L))
  }

  remove <- files[!keep]
  if (!length(remove)) return(data.frame())
  remove_info <- file.info(remove)
  out <- data.frame(
    check_type = check_type,
    model_key = model_key,
    root = normalize_loose(root),
    file = normalize_loose(remove),
    relative_file = substring(normalize_loose(remove), nchar(paste0(normalize_loose(model_dir), "/")) + 1L),
    bytes = suppressWarnings(as.numeric(remove_info$size)),
    stringsAsFactors = FALSE
  )
  unlink(remove, recursive = FALSE, force = TRUE)
  out
}

mfclshiny_payload_tool_env <- function(required_for) {
  if (!requireNamespace("mfclshiny", quietly = TRUE)) {
    stop("mfclshiny is required to build compact ", required_for, " payloads.", call. = FALSE)
  }
  tool <- system.file("app", "tools", "model_payload.R", package = "mfclshiny")
  if (!nzchar(tool) || !file.exists(tool)) {
    stop("Could not find mfclshiny model_payload.R for compact ", required_for, " payloads.", call. = FALSE)
  }
  tool_env <- new.env(parent = globalenv())
  sys.source(tool, envir = tool_env, keep.source = FALSE)
  tool_env
}

enrich_jitter_payloads <- function() {
  jitter_root <- file.path(model_dir, "jitter")
  seed_dirs <- list.dirs(jitter_root, recursive = FALSE, full.names = TRUE)
  seed_dirs <- seed_dirs[grepl("^jitter_seed_[0-9]+$", basename(seed_dirs))]
  if (!length(seed_dirs)) return(invisible(data.frame()))

  tool_env <- mfclshiny_payload_tool_env("jitter")
  rows <- lapply(seed_dirs, function(seed_dir) {
    payload <- tool_env$mp_build_jitter_payload(seed_dir)
    out_file <- file.path(seed_dir, "jitter_result.rds")
    saveRDS(payload, out_file, compress = "xz")
    data.frame(
      check_type = check_type,
      model_key = model_key,
      payload_role = "jitter_result",
      folder = normalize_loose(seed_dir),
      payload = normalize_loose(out_file),
      bytes = suppressWarnings(as.numeric(file.info(out_file)$size)),
      stringsAsFactors = FALSE
    )
  })
  out <- bind_rows_fill(rows)
  write.csv(out, file.path(model_dir, "jitter-payload-index.csv"), row.names = FALSE)
  invisible(out)
}

ensure_profile_payloads <- function() {
  profile_root <- file.path(model_dir, "profile")
  scalar_dirs <- list.dirs(profile_root, recursive = TRUE, full.names = TRUE)
  scalar_dirs <- scalar_dirs[grepl("^scalar_", basename(scalar_dirs))]
  if (!length(scalar_dirs)) return(invisible(data.frame()))

  missing <- scalar_dirs[!file.exists(file.path(scalar_dirs, "profile_payload.rds"))]
  if (length(missing)) {
    tool_env <- mfclshiny_payload_tool_env("profile")
    for (scalar_dir in missing) {
      payload <- tool_env$mp_build_profile_payload(scalar_dir)
      saveRDS(payload, file.path(scalar_dir, "profile_payload.rds"), compress = "xz")
    }
  }
  rows <- lapply(scalar_dirs, function(scalar_dir) {
    payload <- file.path(scalar_dir, "profile_payload.rds")
    data.frame(
      check_type = check_type,
      model_key = model_key,
      payload_role = "profile_payload",
      folder = normalize_loose(scalar_dir),
      payload = normalize_loose(payload),
      bytes = suppressWarnings(as.numeric(file.info(payload)$size)),
      stringsAsFactors = FALSE
    )
  })
  out <- bind_rows_fill(rows)
  write.csv(out, file.path(model_dir, "profile-payload-index.csv"), row.names = FALSE)
  invisible(out)
}

enrich_aspm_payload <- function() {
  aspm_dir <- file.path(model_dir, "aspm")
  if (!dir.exists(aspm_dir)) return(invisible(data.frame()))
  if (!requireNamespace("mfclshiny", quietly = TRUE)) {
    stop("mfclshiny is required to build compact ASPM payloads.", call. = FALSE)
  }

  tool_env <- mfclshiny_payload_tool_env("ASPM")
  payload <- tool_env$mp_build_model_payload(aspm_dir)
  payload_file <- file.path(aspm_dir, "model_payload.rds")
  saveRDS(payload, payload_file, compress = "xz")
  if ("write_model_payload_manifest" %in% getNamespaceExports("mfclshiny")) {
    mfclshiny::write_model_payload_manifest(payload = payload, folder = aspm_dir, payload_file = payload_file)
  }

  out <- data.frame(
    check_type = check_type,
    model_key = model_key,
    payload_role = "aspm_model_payload",
    folder = normalize_loose(aspm_dir),
    payload = normalize_loose(payload_file),
    bytes = suppressWarnings(as.numeric(file.info(payload_file)$size)),
    stringsAsFactors = FALSE
  )
  write.csv(out, file.path(model_dir, "aspm-payload-index.csv"), row.names = FALSE)
  invisible(out)
}

enrich_check_payloads <- function() {
  if (!truthy(env("CHECK_ENRICH_PAYLOADS", "true"), TRUE)) return(invisible(data.frame()))
  if (identical(check_type, "jitter")) return(enrich_jitter_payloads())
  if (identical(check_type, "profile")) return(ensure_profile_payloads())
  if (identical(check_type, "aspm")) return(enrich_aspm_payload())
  invisible(data.frame())
}

compact_check_outputs <- function() {
  if (!check_compact_outputs_enabled()) return(invisible(data.frame()))

  log_patterns <- c("(^|/).*log($|[.])", "(^|/)mfcl.*[.]txt$")
  deleted <- list()
  if (identical(check_type, "jitter")) {
    seed_dirs <- list.dirs(file.path(model_dir, "jitter"), recursive = FALSE, full.names = TRUE)
    seed_dirs <- seed_dirs[grepl("^jitter_seed_[0-9]+$", basename(seed_dirs))]
    deleted <- lapply(seed_dirs, compact_prune_files,
      keep_names = c("jitter_result.rds", "jitter_info.rds"),
      keep_patterns = c(log_patterns, "^jitter_seed_[0-9]+_(label_changes|summary)[.]csv$"),
      recursive = TRUE
    )
  } else if (identical(check_type, "retro")) {
    peel_dirs <- list.dirs(file.path(model_dir, "retro"), recursive = FALSE, full.names = TRUE)
    peel_dirs <- peel_dirs[grepl("^peel_[0-9]+$", basename(peel_dirs))]
    deleted <- lapply(peel_dirs, compact_prune_files,
      keep_names = c("retro_info.rds", "retro_metrics.rds", "retro_input_info.rds", "hessian_info.rds"),
      keep_patterns = c(log_patterns, "(^|/)neigenvalues$"),
      recursive = TRUE
    )
  } else if (identical(check_type, "profile")) {
    scalar_dirs <- list.dirs(file.path(model_dir, "profile"), recursive = TRUE, full.names = TRUE)
    scalar_dirs <- scalar_dirs[grepl("^scalar_", basename(scalar_dirs))]
    deleted <- lapply(scalar_dirs, compact_prune_files,
      keep_names = c("profile_payload.rds", "profile_point_info.rds", "info.rds", "test_plot_output", "hessian_info.rds"),
      keep_patterns = c(log_patterns, "(^|/)neigenvalues$"),
      recursive = TRUE
    )
  } else if (identical(check_type, "aspm")) {
    deleted <- list(compact_prune_files(
      file.path(model_dir, "aspm"),
      keep_names = c(
        "model_payload.rds",
        "model_payload_manifest.json",
        "model_payload_manifest.csv",
        "aspm_info.rds",
        "aspm-index.csv",
        "aspm_control.txt",
        "run_aspm.sh"
      ),
      keep_patterns = log_patterns,
      recursive = TRUE
    ))
  } else if (identical(check_type, "hessian")) {
    part_dirs <- list.dirs(file.path(model_dir, "hessian"), recursive = FALSE, full.names = TRUE)
    part_dirs <- part_dirs[grepl("^part_[0-9]+$", basename(part_dirs))]
    deleted <- lapply(part_dirs, compact_prune_files,
      keep_names = c("hessian_info.rds", "mfcl_hessian_log.txt", "depgrad.rpt", "Hess.rpt", "neigenvalues"),
      keep_patterns = c(log_patterns, "[.]hes$"),
      recursive = TRUE
    )
  }

  out <- bind_rows_fill(deleted)
  compact_prune_empty_dirs(model_dir)
  if (nrow(out)) {
    out$removed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    write.csv(out, file.path(model_dir, "check-output-cleanup.csv"), row.names = FALSE)
    saveRDS(out, file.path(model_dir, "check-output-cleanup.rds"), compress = "xz")
    message("[checks] compacted ", check_type, " output: removed ", nrow(out), " raw/intermediate files")
  }
  invisible(out)
}

write_run_manifest <- function(extra = list()) {
  manifest <- c(
    list(
      check_type = check_type,
      model_key = model_key,
      case_dir = prepared$case_dir,
      model_dir = normalizePath(model_dir, winslash = "/", mustWork = FALSE),
      program_path = program_path,
      frq = frq_name,
      start_par = start_par_name
    ),
    extra
  )
  saveRDS(manifest, file.path(model_dir, "check_manifest.rds"), compress = "xz")
  write.csv(as.data.frame(manifest, stringsAsFactors = FALSE), file.path(model_dir, "check_manifest.csv"), row.names = FALSE)
  invisible(manifest)
}

stage_report_model_payload()

if (truthy(env("CHECK_DRY_RUN", env("CHECK_SMOKE_ONLY", "false")), FALSE)) {
  write_run_manifest(list(
    dry_run = TRUE,
    reason = "staged input model and skipped MFCL execution"
  ))
  write_check_payload_index()
  message("[checks] dry run complete; staged ", prepared$case_dir)
  quit(save = "no", status = 0)
}

message("[checks] running ", check_type, " for ", model_key)

if (identical(check_type, "jitter")) {
  seeds <- as.integer(split_numbers(env("JITTER_SEEDS", env("JITTER_SEED", "1")), default = 1))
  cv <- split_numbers(env("JITTER_CV", "0.2"), default = 0.2)[[1L]]
  slots <- check_jitter_slots()
  jitter_command <- check_final_phase_command()
  write_run_manifest(list(
    jitter_seeds = paste(seeds, collapse = " "),
    jitter_cv = cv,
    jitter_slots = paste(slots, collapse = " ")
  ))
  result <- mfk_run_jitter(
    backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    seeds = seeds,
    cv = cv,
    jitter_args = list(include_slots = slots),
    par = prepared$start_par,
    start_par_name = "00.par",
    command = jitter_command,
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  saveRDS(result, file.path(model_dir, "jitter_runs.rds"), compress = "xz")
  try(write.csv(mfk_collect_jitter(model_dir), file.path(model_dir, "jitter-index.csv"), row.names = FALSE), silent = TRUE)

} else if (identical(check_type, "retro")) {
  peels <- as.integer(split_numbers(env("RETRO_PEELS", env("RETRO_PEEL", "1")), default = 1))
  n_mixing_periods <- as.integer(split_numbers(env("N_MIXING_PERIODS", "2"), default = 2)[[1L]])
  write_run_manifest(list(retro_peels = paste(peels, collapse = " "), n_mixing_periods = n_mixing_periods))
  retro_command <- split_values(env("RETRO_COMMAND", ""))
  retro_args <- list(
    backend = backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    peel = peels,
    n_mixing_periods = n_mixing_periods,
    allow_new_ini_version_write = truthy(env("RETRO_ALLOW_NEW_INI_VERSION_WRITE", "false"), FALSE),
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  if (length(retro_command)) {
    retro_args$command <- retro_command
  } else if (!truthy(env("RETRO_USE_DOITALL", "true"), TRUE)) {
    retro_args$command <- mfcl_command(output_par = "retro.par")
  }
  result <- do.call(mfk_run_retro, retro_args)
  saveRDS(result, file.path(model_dir, "retro_runs.rds"), compress = "xz")

} else if (identical(check_type, "hessian")) {
  nsplit <- as.integer(split_numbers(env("HESSIAN_NSPLIT", env("NSPLIT", "1")), default = 1)[[1L]])
  part_values <- split_numbers(env("HESSIAN_PARTS", env("HESSIAN_PART", "")), default = seq_len(nsplit))
  parts <- as.integer(part_values)
  stitch_inputs <- stage_hessian_stitch_inputs()
  write_run_manifest(list(
    hessian_nsplit = nsplit,
    hessian_parts = paste(parts, collapse = " "),
    hessian_stitch_inputs = paste(names(stitch_inputs)[stitch_inputs], collapse = " ")
  ))
  result <- lapply(parts, function(part) {
    mfk_run_hessian_part(
      backend,
      input_dir = prepared$case_dir,
      output_dir = file.path(model_dir, "hessian", paste0("part_", part)),
      part = part,
      nsplit = nsplit,
      par = prepared$start_par,
      frq = prepared$frq,
      compact = truthy(env("HESSIAN_COMPACT", "true"), TRUE),
      run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
    )
  })
  saveRDS(result, file.path(model_dir, "hessian_runs.rds"), compress = "xz")

} else if (identical(check_type, "profile")) {
  profile_type <- env("PROFILE_TYPE", "quantity")
  profile_name <- env("PROFILE_NAME", if (identical(profile_type, "quantity")) "adult_biomass" else "profile")
  profile_values <- split_numbers(env("PROFILE_VALUES", env("MFK_SCALAR", "")), default = seq(70, 130, by = 10))
  profile_label <- env("PROFILE_LABEL", profile_name)

  if (identical(profile_type, "quantity")) {
    quantity <- env("PROFILE_QUANTITY", "avg_bio")
    quantity_type <- suppressWarnings(as.integer(env("PROFILE_QUANTITY_TYPE", NA_character_)))
    base_quantity <- suppressWarnings(as.numeric(env("PROFILE_BASE_QUANTITY", NA_character_)))
    if (!is.finite(base_quantity)) base_quantity <- NULL
    profile <- mfk_quantity_profile_from_model(
      model_dir = prepared$case_dir,
      name = profile_name,
      values = profile_values,
      quantity = quantity,
      quantity_type = quantity_type,
      base_quantity = base_quantity,
      Af172 = as.integer(split_numbers(env("PROFILE_AF172", "1"), default = 1)[[1L]]),
      Af173 = as.integer(split_numbers(env("PROFILE_AF173", "0"), default = 0)[[1L]]),
      Af174 = as.integer(split_numbers(env("PROFILE_AF174", "0"), default = 0)[[1L]]),
      penalty = split_numbers(env("PROFILE_PENALTY", "1e7"), default = 1e7)[[1L]],
      reps = env("PROFILE_REPS", "15 25 25 500 500 200"),
      extra_switch = env("PROFILE_EXTRA_SWITCH", "")
    )
    write_run_manifest(list(profile_type = profile_type, profile_name = profile_name, profile_quantity = quantity))
    result <- mfk_run_profile(
      backend,
      input_dir = prepared$case_dir,
      model_dir = model_dir,
      profile = profile,
      command_fun = function(profile_row, chain_start_par = NULL, ...) {
        mfcl_command(
          input_par = profile_input_par(chain_start_par),
          output_par = "profile.par",
          extra = mfk_quantity_profile_switch(profile_row)
        )
      },
      chain = truthy(env("PROFILE_CHAIN", "false"), FALSE),
      run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
    )
  } else if (identical(profile_type, "fixed_parameter")) {
    parameter <- env("PROFILE_PARAMETER", "")
    apply_script <- env("PROFILE_APPLY_SCRIPT", "")
    if (!nzchar(parameter)) stop("PROFILE_PARAMETER is required for fixed_parameter profiles.", call. = FALSE)
    if (!nzchar(apply_script) || !file.exists(apply_script)) {
      stop("PROFILE_APPLY_SCRIPT is required for fixed_parameter profiles. It must edit each point_dir for the requested parameter.", call. = FALSE)
    }
    profile <- mfk_parameter_profile(profile_name, parameter = parameter, values = profile_values, label = profile_label)
    write_run_manifest(list(profile_type = profile_type, profile_name = profile_name, profile_parameter = parameter, profile_apply_script = apply_script))
    result <- mfk_run_profile(
      backend,
      input_dir = prepared$case_dir,
      model_dir = model_dir,
      profile = profile,
      apply_fun = function(point_dir, scalar, profile_row) {
        profile_env <- new.env(parent = parent.frame())
        sys.source(apply_script, envir = profile_env)
        if (!exists("apply_profile_point", envir = profile_env, mode = "function")) {
          stop("PROFILE_APPLY_SCRIPT must define apply_profile_point(point_dir, scalar, profile_row).", call. = FALSE)
        }
        get("apply_profile_point", envir = profile_env)(point_dir, scalar, profile_row)
      },
      command_fun = function(profile_row, chain_start_par = NULL, ...) {
        mfcl_command(input_par = profile_input_par(chain_start_par), output_par = "profile.par")
      },
      chain = truthy(env("PROFILE_CHAIN", "false"), FALSE),
      run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
    )
  } else {
    stop("Unsupported PROFILE_TYPE: ", profile_type, call. = FALSE)
  }
  saveRDS(result, file.path(model_dir, "profile_runs.rds"), compress = "xz")
  points <- mfk_read_profile_points(file.path(model_dir, "profile", profile_name))
  write.csv(points, file.path(model_dir, "profile-points.csv"), row.names = FALSE)
  if (nrow(points)) {
    write.csv(mfk_profile_conflict_metrics(points), file.path(model_dir, "profile-qc.csv"), row.names = FALSE)
  }

} else if (identical(check_type, "aspm")) {
  max_evals <- as.integer(split_numbers(env("ASPM_MAX_EVALS", "10000"), default = 10000)[[1L]])
  min_lf_sample_size <- split_numbers(env("ASPM_MIN_LF_SAMPLE_SIZE", "1000000"), default = 1000000)[[1L]]
  min_wf_sample_size <- split_numbers(env("ASPM_MIN_WF_SAMPLE_SIZE", "1000000"), default = 1000000)[[1L]]
  lf_flag_311 <- as.integer(split_numbers(env("ASPM_LF_FLAG_311", "11"), default = 11)[[1L]])
  wf_flag_301 <- as.integer(split_numbers(env("ASPM_WF_FLAG_301", "1"), default = 1)[[1L]])
  fix_selectivity <- truthy(env("ASPM_FIX_SELECTIVITY", "true"), TRUE)
  output_par <- env("ASPM_OUTPUT_PAR", "aspm.par")
  write_run_manifest(list(
    aspm_max_evals = max_evals,
    aspm_min_lf_sample_size = min_lf_sample_size,
    aspm_min_wf_sample_size = min_wf_sample_size,
    aspm_lf_flag_311 = lf_flag_311,
    aspm_wf_flag_301 = wf_flag_301,
    aspm_fix_selectivity = fix_selectivity,
    aspm_output_par = output_par
  ))
  result <- mfk_run_aspm(
    backend,
    input_dir = prepared$case_dir,
    output_dir = file.path(model_dir, "aspm"),
    frq = prepared$frq,
    input_par = prepared$start_par,
    output_par = output_par,
    max_evals = max_evals,
    fix_selectivity = fix_selectivity,
    lf_flag_311 = lf_flag_311,
    wf_flag_301 = wf_flag_301,
    min_lf_sample_size = min_lf_sample_size,
    min_wf_sample_size = min_wf_sample_size,
    extra_switch_lines = aspm_extra_switch_lines(),
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  saveRDS(result, file.path(model_dir, "aspm_runs.rds"), compress = "xz")
  try(write.csv(mfk_collect_aspm(model_dir), file.path(model_dir, "aspm-index.csv"), row.names = FALSE), silent = TRUE)

} else if (identical(check_type, "selftest")) {
  runner <- resolve_selftest_runner(env("SELFTEST_RUNNER", ""))
  if (nzchar(runner) && !file.exists(runner)) {
    stop(
      "Native MFCL selftest runner was not found: ", runner,
      ". SELFTEST_RUNNER_REPO=", env("SELFTEST_RUNNER_REPO", env("CHECK_SELFTEST_REPO", "")),
      ", SELFTEST_RUNNER_REF=", env("SELFTEST_RUNNER_REF", env("CHECK_SELFTEST_REF", "")),
      call. = FALSE
    )
  }
  runner_work_dir <- env("SELFTEST_RUNNER_WORK_DIR", env("CHECK_SELFTEST_WORK_DIR", attr(runner, "runner_work_dir") %||% ""))
  reps <- as.integer(split_numbers(env("SELFTEST_REPS", env("SELFTEST_REP", "1")), default = 1))
  seed <- as.integer(split_numbers(env("SELFTEST_SEED", "20260519"), default = 20260519)[[1L]])
  write_run_manifest(list(
    selftest_reps = paste(reps, collapse = " "),
    selftest_seed = seed,
    selftest_runner = if (nzchar(runner)) runner else "mfclkit::mfk_selftest_runner_path()",
    selftest_runner_work_dir = runner_work_dir
  ))
  args <- list(
    backend = backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    reps = reps,
    seed = seed,
    par = prepared$start_par,
    run_refit = truthy(env("SELFTEST_RUN_REFIT", "true"), TRUE)
  )
  if (!nzchar(Sys.getenv("selftest_compact_cleanup", ""))) {
    Sys.setenv(selftest_compact_cleanup = env("SELFTEST_COMPACT_CLEANUP", "1"))
  }
  if (!nzchar(Sys.getenv("selftest_keep_model_payload", ""))) {
    Sys.setenv(selftest_keep_model_payload = env("SELFTEST_KEEP_MODEL_PAYLOAD", "0"))
  }
  if (!nzchar(Sys.getenv("selftest_keep_sim_debug", ""))) {
    Sys.setenv(selftest_keep_sim_debug = env("SELFTEST_KEEP_SIM_DEBUG", "0"))
  }
  if (nzchar(runner)) args$runner <- runner
  if (nzchar(runner_work_dir)) args$runner_work_dir <- runner_work_dir
  result <- do.call(mfk_run_selftest, args)
  saveRDS(result, file.path(model_dir, "selftest_runs.rds"), compress = "xz")

} else {
  stop("Unsupported CHECK_TYPE: ", check_type, call. = FALSE)
}

enrich_check_payloads()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
compact_check_outputs()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
payload_index <- build_report_payloads()
write_check_payload_index(payload_index)
build_report_ready_figures()
message("[checks] wrote outputs under ", model_dir)
