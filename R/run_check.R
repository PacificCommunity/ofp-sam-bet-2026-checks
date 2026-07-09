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
check_start_par <- tryCatch(
  mfclkit::mfk_latest_par(prepared$case_dir, required = FALSE),
  error = function(e) NA_character_
)
if (!file.exists(check_start_par)) check_start_par <- prepared$start_par
start_par_name <- basename(check_start_par)
if (!identical(normalize_loose(check_start_par), normalize_loose(prepared$start_par))) {
  message("[checks] using fitted start par ", start_par_name,
          " instead of staged ", basename(prepared$start_par))
}

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

check_status_success <- function(dat) {
  if (!is.data.frame(dat) || !nrow(dat)) return(logical())
  if ("success" %in% names(dat)) {
    success <- suppressWarnings(as.logical(dat$success))
    success[is.na(success)] <- FALSE
    return(success)
  }
  status_names <- intersect(c("run_status", "status", "convergence_status"), names(dat))
  if (!length(status_names) && "n_failed" %in% names(dat)) {
    failed <- suppressWarnings(as.integer(dat$n_failed))
    success <- is.finite(failed) & failed == 0L
    success[is.na(success)] <- FALSE
    return(success)
  }
  bad_status <- rep(FALSE, nrow(dat))
  for (name in status_names) {
    if (name %in% names(dat)) {
      value <- tolower(trimws(as.character(dat[[name]])))
      value <- value[nzchar(value)]
      if (!length(value)) next
      bad <- value %in% c(
        "failed", "error", "model_run_failed", "completed_with_nonzero_status",
        "completed_not_converged", "not_completed", "not_converged",
        "blocked_by_previous_profile_point", "unknown", "status_collect_failed"
      ) | grepl("failed|error|not[-_ ]?converged|not[-_ ]?completed|blocked", value)
      idx <- which(nzchar(tolower(trimws(as.character(dat[[name]])))))
      bad_status[idx] <- bad_status[idx] | bad
    }
  }
  success <- !bad_status
  if ("run_completed" %in% names(dat)) {
    completed <- suppressWarnings(as.logical(dat$run_completed))
    success <- success & (is.na(completed) | completed)
  }
  if ("converged" %in% names(dat)) {
    converged <- suppressWarnings(as.logical(dat$converged))
    success <- success & (is.na(converged) | converged)
  }
  if ("input_built" %in% names(dat)) {
    input_built <- suppressWarnings(as.logical(dat$input_built))
    success <- success & !is.na(input_built) & input_built
  }
  for (name in intersect(c("sim_status", "refit_status"), names(dat))) {
    value <- suppressWarnings(as.integer(dat[[name]]))
    success <- success & (is.na(value) | value == 0L)
  }
  if ("total_nll" %in% names(dat)) {
    total_nll <- suppressWarnings(as.numeric(dat$total_nll))
    success <- success & is.finite(total_nll)
  }
  if ("output_hessian" %in% names(dat)) {
    output_hessian <- trimws(as.character(dat$output_hessian))
    success <- success & nzchar(output_hessian) & !is.na(output_hessian)
  }
  success
}

collect_check_unit_status <- function(model_dir, check_type) {
  out <- tryCatch({
    if (identical(check_type, "jitter")) {
      mfclkit::mfk_collect_jitter(model_dir)
    } else if (identical(check_type, "retro")) {
      mfclkit::mfk_collect_retro(model_dir)
    } else if (identical(check_type, "aspm")) {
      mfclkit::mfk_collect_aspm(model_dir)
    } else if (identical(check_type, "profile")) {
      roots <- list.dirs(file.path(model_dir, "profile"), recursive = FALSE, full.names = TRUE)
      bind_rows_fill(lapply(roots, mfclkit::mfk_read_profile_points))
    } else if (identical(check_type, "selftest")) {
      candidates <- c(
        file.path(model_dir, "selftest", "selftest_runs.rds"),
        file.path(model_dir, "selftest_runs.rds")
      )
      found <- data.frame(stringsAsFactors = FALSE)
      for (path in candidates[file.exists(candidates)]) {
        dat <- tryCatch(readRDS(path), error = function(e) NULL)
        if (is.data.frame(dat)) {
          found <- dat
          break
        }
      }
      if (nrow(found)) {
        found
      } else {
        refits <- list.dirs(file.path(model_dir, "selftest", "refit"),
                            recursive = FALSE, full.names = TRUE)
        rows <- lapply(refits, function(dir) {
          info <- tryCatch(readRDS(file.path(dir, "model_info.rds")),
                           error = function(e) NULL)
          data.frame(
            rep = sub("^rep_", "", basename(dir)),
            run_status = as.character(info$run_status %||% info$status %||% "unknown"),
            run_completed = isTRUE(info$run_completed %||% FALSE),
            convergence_status = as.character(info$convergence_status %||% ""),
            converged = isTRUE(info$converged %||% FALSE),
            failure_reason = as.character(info$failure_reason %||% ""),
            folder = normalize_loose(dir),
            stringsAsFactors = FALSE
          )
        })
        bind_rows_fill(rows)
      }
    } else if (identical(check_type, "hessian")) {
      part_dirs <- list.dirs(file.path(model_dir, "hessian"), recursive = FALSE, full.names = TRUE)
      part_dirs <- part_dirs[grepl("^part_[0-9]+$", basename(part_dirs))]
      if (length(part_dirs)) {
        bind_rows_fill(lapply(part_dirs, function(dir) {
          hinfo <- tryCatch(readRDS(file.path(dir, "hessian_info.rds")),
                            error = function(e) NULL)
          data.frame(
            unit = basename(dir),
            part = suppressWarnings(as.integer(hinfo$hessian_part %||% sub("^part_", "", basename(dir)))),
            run_status = as.character(hinfo$run_status %||% "unknown"),
            run_completed = !is.null(hinfo) && !identical(hinfo$run_status, "model_run_failed"),
            converged = !is.null(hinfo) && !identical(hinfo$run_status, "model_run_failed"),
            output_hessian = as.character(hinfo$output_hessian %||% NA_character_),
            failure_reason = as.character(hinfo$error %||% ""),
            folder = normalize_loose(dir),
            stringsAsFactors = FALSE
          )
        }))
      } else {
        hinfo <- tryCatch(readRDS(file.path(model_dir, "hessian", "hessian_info.rds")),
                          error = function(e) NULL)
        data.frame(
          unit = "hessian",
          run_status = as.character(hinfo$eigen$hessian_status %||% hinfo$run_status %||% "unknown"),
          run_completed = !is.null(hinfo),
          converged = suppressWarnings(as.logical(hinfo$diagnostics$summary$hessian_ok %||% NA)),
          failure_reason = as.character(hinfo$stitch$command$error %||% hinfo$error %||% ""),
          folder = normalize_loose(file.path(model_dir, "hessian")),
          stringsAsFactors = FALSE
        )
      }
    } else {
      data.frame(stringsAsFactors = FALSE)
    }
  }, error = function(e) {
    data.frame(
      run_status = "status_collect_failed",
      run_completed = FALSE,
      converged = FALSE,
      failure_reason = conditionMessage(e),
      stringsAsFactors = FALSE
    )
  })
  if (!is.data.frame(out)) out <- data.frame(stringsAsFactors = FALSE)
  if (nrow(out)) {
    out$check_type <- check_type
    success <- check_status_success(out)
    if (length(success) != nrow(out)) success <- rep(FALSE, nrow(out))
    out$success <- success
  }
  out
}

write_check_status_summary <- function(model_dir, check_type) {
  units <- collect_check_unit_status(model_dir, check_type)
  if (nrow(units)) {
    write.csv(units, file.path(model_dir, "check-unit-status.csv"), row.names = FALSE)
    saveRDS(units, file.path(model_dir, "check-unit-status.rds"), compress = "xz")
  }
  n_units <- nrow(units)
  n_success <- if (n_units) sum(units$success %in% TRUE, na.rm = TRUE) else 0L
  n_failed <- if (n_units) sum(!(units$success %in% TRUE), na.rm = TRUE) else 0L
  requires_all_units <- check_type %in% c("profile", "hessian")
  has_failures <- n_failed > 0L || n_units == 0L
  merge_status <- if (!n_units) {
    "no_units"
  } else if (requires_all_units && n_failed > 0L) {
    "incomplete"
  } else if (n_failed > 0L) {
    "complete_with_failed_units"
  } else {
    "complete"
  }
  summary <- data.frame(
    check_type = check_type,
    model_key = model_key,
    n_units = n_units,
    n_success = n_success,
    n_failed = n_failed,
    has_failures = has_failures,
    requires_all_units = requires_all_units,
    all_required_units_successful = !requires_all_units || (n_units > 0L && n_failed == 0L),
    merge_status = merge_status,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  write.csv(summary, file.path(model_dir, "check-summary.csv"), row.names = FALSE)
  saveRDS(as.list(summary), file.path(model_dir, "check-summary.rds"), compress = "xz")
  invisible(summary)
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
  copy_if_exists(check_start_par, model_dir, basename(check_start_par))
  copy_existing_diagnostic_dirs(compact_dir, model_dir, exclude = check_type)

  index <- check_model_index_row()
  write_check_model_indices(index)
  augment_base_payload_manifest(index)
  invisible(index)
}

safe_path_token <- function(value, default = "unit") {
  token <- gsub("[^A-Za-z0-9_.-]+", "_", as.character(value %||% default))
  token <- gsub("^_+|_+$", "", token)
  if (nzchar(token)) token else default
}

write_smoke_marker <- function(dir, data) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  data$smoke <- TRUE
  data$created_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  write.csv(data, file.path(dir, "smoke-check.csv"), row.names = FALSE)
  saveRDS(data, file.path(dir, "smoke-check.rds"), compress = "xz")
  invisible(dir)
}

write_smoke_jitter_payload <- function(dir, seed) {
  seed_int <- suppressWarnings(as.integer(seed))
  if (!is.finite(seed_int)) seed_int <- NA_integer_
  created_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  base_obj <- base_payload_number("obj_fun", 0)
  base_grad <- base_payload_number("max_grad", 0)
  state <- list(
    run_status = "smoke_completed",
    run_completed = TRUE,
    convergence_status = "smoke_only",
    converged = TRUE,
    jitter_cv = NA_real_,
    obj_fun = base_obj + abs(seed_int %||% 0L) * 0.001,
    max_grad = base_grad,
    exit_status = 0L
  )
  empty_changes <- list(
    files = NULL,
    labels = data.frame(stringsAsFactors = FALSE),
    summary = data.frame(stringsAsFactors = FALSE),
    family_stats = data.frame(stringsAsFactors = FALSE),
    overall_stats = data.frame(stringsAsFactors = FALSE)
  )
  info <- list(
    seed = seed_int,
    jitter_cv = NA_real_,
    smoke = TRUE,
    created_at = created_at,
    output_par = NA_character_,
    state = state,
    mfcl_run = state
  )
  payload <- list(
    version = "v1",
    created_at = created_at,
    seed_dir = normalize_loose(dir),
    seed = seed_int,
    jitter_cv = NA_real_,
    run_status = "smoke_completed",
    run_completed = TRUE,
    convergence_status = "smoke_only",
    converged = TRUE,
    state = state,
    success = TRUE,
    exit_status = 0L,
    failure_reason = NA_character_,
    output_par_exists = FALSE,
    obj_fun = state$obj_fun,
    max_grad = state$max_grad,
    output_par = NA_character_,
    parameter_changes = empty_changes,
    fitted_parameter_changes = empty_changes,
    derived_quantities = data.frame(stringsAsFactors = FALSE),
    age_curves = data.frame(stringsAsFactors = FALSE),
    hessian_ok = NA,
    hessian_info = list(
      requested = FALSE,
      attempted = FALSE,
      run_ok = NA,
      pdh = NA,
      spd = NA,
      n_negative_eigenvalues = NA_integer_,
      n_total_eigenvalues = NA_integer_,
      hessian_status = "not_requested",
      reliability = NA_character_,
      error = NA_character_
    ),
    hessian = NULL,
    mfcl_run = state,
    run_checks = list(
      run_status = "smoke_completed",
      run_completed = TRUE,
      convergence_status = "smoke_only",
      converged = TRUE,
      failure_reason = NA_character_
    )
  )
  saveRDS(info, file.path(dir, "jitter_info.rds"), compress = "xz")
  saveRDS(payload, file.path(dir, "jitter_result.rds"), compress = "xz")
  invisible(payload)
}

read_base_payload <- function() {
  payload_file <- file.path(model_dir, "model_payload.rds")
  if (!file.exists(payload_file)) return(NULL)
  tryCatch(readRDS(payload_file), error = function(e) NULL)
}

base_payload_number <- function(name, default = NA_real_) {
  payload <- read_base_payload()
  value <- suppressWarnings(as.numeric(tryCatch(payload[[name]], error = function(e) NA_real_)))
  if (!length(value) || !is.finite(value[[1L]])) default else value[[1L]]
}

copy_base_payload_files <- function(to_dir) {
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  files <- c(
    "model_payload.rds",
    "model_payload_manifest.json",
    "model_payload_manifest.csv",
    "model_info.rds",
    "final.par"
  )
  copied <- vapply(file.path(model_dir, files), copy_if_exists, logical(1), to_dir = to_dir)
  invisible(copied)
}

write_smoke_profile_payload <- function(dir, value, profile_name, chain_side = "") {
  created_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  center <- split_numbers(env("PROFILE_CENTER", ""), default = value)[[1L]]
  rel <- if (is.finite(center) && abs(center) > 0) (value - center) / abs(center) else 0
  obj_fun <- base_payload_number("obj_fun", 0) + 100 * rel^2
  max_grad <- base_payload_number("max_grad", 0)
  info <- list(
    version = "v1",
    created_at = created_at,
    profile = profile_name,
    profile_set_key = profile_name,
    profile_set_label = profile_name,
    scalar = value,
    scaler = value,
    quantity_label = env("PROFILE_LABEL", profile_name),
    reference_quantity = center,
    target_quantity = value,
    actual_quantity = value,
    target_rel_err = rel,
    obj_fun = obj_fun,
    total_nll = obj_fun,
    max_grad = max_grad,
    run_status = "smoke_completed",
    run_completed = TRUE,
    convergence_status = "smoke_only",
    chain_side = chain_side,
    smoke = TRUE
  )
  payload <- c(
    info,
    list(
      scalar_dir = normalize_loose(dir),
      has_test_plot_output = FALSE,
      lik_out = NULL,
      lik_raw = NULL,
      mfclkit = info
    )
  )
  saveRDS(info, file.path(dir, "profile_point_info.rds"), compress = "xz")
  saveRDS(info, file.path(dir, "info.rds"), compress = "xz")
  saveRDS(payload, file.path(dir, "profile_payload.rds"), compress = "xz")
  invisible(payload)
}

base_retro_metrics <- function(peel) {
  payload <- read_base_payload()
  rep_obj <- tryCatch(payload$data$RepOut, error = function(e) NULL)
  metrics <- if (!is.null(rep_obj) && requireNamespace("mfclkit", quietly = TRUE)) {
    tryCatch(mfclkit::mfk_retro_metrics(rep_obj, scenario = model_key, peel = as.integer(peel)), error = function(e) NULL)
  } else {
    NULL
  }
  if (!is.data.frame(metrics) || !nrow(metrics)) {
    par_obj <- tryCatch(payload$data$ParOut, error = function(e) NULL)
    years <- suppressWarnings(as.integer(c(
      tryCatch(par_obj@range["minyear"], error = function(e) NA_integer_),
      tryCatch(par_obj@range["maxyear"], error = function(e) NA_integer_)
    )))
    years <- years[is.finite(years)]
    years <- if (length(years) >= 2L && diff(range(years)) > 0L) {
      seq.int(min(years), max(years))
    } else {
      1952:2024
    }
    n <- length(years)
    metrics <- data.frame(
      year = years,
      depletion = seq(0.95, 0.62, length.out = n),
      spawning_potential = seq(6000, 2200, length.out = n),
      recruitment = 180 + 40 * sin(seq_len(n) / 4),
      fishing_mortality = seq(0.01, 0.18, length.out = n),
      scenario = model_key,
      peel = as.integer(peel),
      smoke = TRUE,
      stringsAsFactors = FALSE
    )
  }
  metrics$peel <- as.integer(peel)
  if ("year" %in% names(metrics)) {
    year <- suppressWarnings(as.numeric(metrics$year))
    max_year <- max(year[is.finite(year)], na.rm = TRUE)
    if (is.finite(max_year)) metrics <- metrics[year <= max_year - as.integer(peel), , drop = FALSE]
  }
  if ("depletion" %in% names(metrics)) metrics$depletion <- suppressWarnings(as.numeric(metrics$depletion)) * (1 - 0.005 * as.integer(peel))
  if ("spawning_potential" %in% names(metrics)) metrics$spawning_potential <- suppressWarnings(as.numeric(metrics$spawning_potential)) * (1 - 0.005 * as.integer(peel))
  metrics
}

write_smoke_retro_payload <- function(dir, peel) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  metrics <- base_retro_metrics(peel)
  if (!is.null(metrics) && nrow(metrics)) {
    saveRDS(metrics, file.path(dir, "retro_metrics.rds"), compress = "xz")
  }
  terminal_year <- if (!is.null(metrics) && nrow(metrics) && "year" %in% names(metrics)) {
    max(suppressWarnings(as.numeric(metrics$year)), na.rm = TRUE) + as.integer(peel)
  } else {
    NA_real_
  }
  info <- list(
    peel = as.integer(peel),
    terminal_year = terminal_year,
    new_max_year = if (is.finite(terminal_year)) terminal_year - as.integer(peel) else NA_real_,
    run_status = "smoke_completed",
    run_completed = TRUE,
    convergence_status = "smoke_only",
    failure_reason = NA_character_,
    output_par = NA_character_,
    output_rep = NA_character_,
    smoke = TRUE
  )
  saveRDS(info, file.path(dir, "retro_info.rds"), compress = "xz")
  invisible(info)
}

write_smoke_selftest_payload <- function(dir, rep) {
  rep_token <- safe_path_token(rep)
  copy_base_payload_files(dir)
  info <- list(
    rep = suppressWarnings(as.integer(rep)),
    run_status = "smoke_completed",
    run_completed = TRUE,
    convergence_status = "smoke_only",
    smoke = TRUE
  )
  saveRDS(info, file.path(dir, "selftest_run_info.rds"), compress = "xz")
  invisible(info)
}

write_smoke_check_outputs <- function() {
  rows <- list()
  add_row <- function(dir, unit_type, unit) {
    rows[[length(rows) + 1L]] <<- data.frame(
      check_type = check_type,
      model_key = model_key,
      unit_type = unit_type,
      unit = as.character(unit),
      unit_dir = normalize_loose(dir),
      stringsAsFactors = FALSE
    )
  }

  if (identical(check_type, "jitter")) {
    seeds <- split_values(env("JITTER_SEEDS", env("JITTER_SEED", "1")), default = "1")
    for (seed in seeds) {
      dir <- file.path(model_dir, "jitter", paste0("jitter_seed_", safe_path_token(seed)))
      write_smoke_marker(dir, data.frame(seed = seed, stringsAsFactors = FALSE))
      write_smoke_jitter_payload(dir, seed)
      add_row(dir, "seed", seed)
    }
  } else if (identical(check_type, "profile")) {
    values <- split_numbers(env("PROFILE_VALUES", env("MFK_SCALAR", "100")), default = 100)
    profile_name <- safe_path_token(env("PROFILE_NAME", "scalar"), "scalar")
    chain_side <- env("PROFILE_CHAIN_SIDE", "")
    for (value in values) {
      value_token <- safe_path_token(format(value, scientific = FALSE, trim = TRUE), "value")
      dir <- file.path(model_dir, "profile", profile_name, paste0("scalar_", value_token))
      write_smoke_marker(dir, data.frame(
        profile_name = profile_name,
        scalar = value,
        chain_side = chain_side,
        stringsAsFactors = FALSE
      ))
      write_smoke_profile_payload(dir, value = value, profile_name = profile_name, chain_side = chain_side)
      add_row(dir, "profile_scalar", value)
    }
  } else if (identical(check_type, "retro")) {
    peels <- split_values(env("RETRO_PEELS", env("RETRO_PEEL", "1")), default = "1")
    for (peel in peels) {
      dir <- file.path(model_dir, "retro", paste0("peel_", safe_path_token(peel)))
      write_smoke_marker(dir, data.frame(peel = peel, stringsAsFactors = FALSE))
      write_smoke_retro_payload(dir, peel)
      add_row(dir, "peel", peel)
    }
  } else if (identical(check_type, "selftest")) {
    reps <- split_values(env("SELFTEST_REPS", env("SELFTEST_REP", "1")), default = "1")
    selftest_rows <- list()
    truth_dir <- file.path(model_dir, "selftest", "truth")
    copy_base_payload_files(truth_dir)
    for (rep in reps) {
      rep_token <- safe_path_token(rep)
      dir <- file.path(model_dir, "selftest", "refit", paste0("rep_", rep_token))
      write_smoke_marker(dir, data.frame(rep = rep, stringsAsFactors = FALSE))
      write_smoke_selftest_payload(dir, rep)
      input_dir <- file.path(model_dir, "selftest", "inputs", paste0("rep_", rep_token))
      dir.create(input_dir, recursive = TRUE, showWarnings = FALSE)
      saveRDS(
        list(rep = suppressWarnings(as.integer(rep)), run_status = "smoke_completed", smoke = TRUE),
        file.path(input_dir, "selftest_input_info.rds"),
        compress = "xz"
      )
      add_row(dir, "replicate", rep)
      selftest_rows[[length(selftest_rows) + 1L]] <- data.frame(
        rep = rep,
        status = "smoke_completed",
        stringsAsFactors = FALSE
      )
    }
    dir.create(file.path(model_dir, "selftest"), recursive = TRUE, showWarnings = FALSE)
    selftest_index <- bind_rows_fill(selftest_rows)
    saveRDS(selftest_index, file.path(model_dir, "selftest", "selftest_runs.rds"), compress = "xz")
    write.csv(selftest_index, file.path(model_dir, "selftest", "selftest_runs.csv"), row.names = FALSE)
  } else if (identical(check_type, "hessian")) {
    parts <- split_values(env("HESSIAN_PARTS", env("HESSIAN_PART", "")))
    if (!length(parts)) parts <- "1"
    nsplit <- env("HESSIAN_NSPLIT", as.character(length(parts)))
    for (part in parts) {
      part_token <- safe_path_token(part)
      dir <- file.path(model_dir, "hessian", paste0("part_", part_token))
      write_smoke_marker(dir, data.frame(
        part = part,
        nsplit = nsplit,
        stringsAsFactors = FALSE
      ))
      saveRDS(
        list(
          schema = "ofp-sam.checks.hessian_smoke.v1",
          check_type = "hessian",
          model_key = model_key,
          part = part,
          nsplit = nsplit,
          smoke = TRUE
        ),
        file.path(dir, "hessian_info.rds"),
        compress = "xz"
      )
      add_row(dir, "hessian_part", part)
    }
  } else {
    dir <- file.path(model_dir, check_type, "smoke_unit")
    write_smoke_marker(dir, data.frame(unit = "smoke", stringsAsFactors = FALSE))
    add_row(dir, "unit", "smoke")
  }

  out <- bind_rows_fill(rows)
  write.csv(out, file.path(model_dir, "smoke-check-index.csv"), row.names = FALSE)
  invisible(out)
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
  if (!truthy(env("CHECK_BUILD_PAYLOADS", env("CHECK_ENRICH_PAYLOADS", "true")), TRUE)) {
    return(invisible(data.frame()))
  }
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
      any(vapply(keep_patterns, grepl, logical(1L), x = base[[i]], ignore.case = TRUE)) ||
        any(vapply(keep_patterns, grepl, logical(1L), x = rel[[i]], ignore.case = TRUE))
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
      keep_patterns = c(log_patterns, "(^|/)neigenvalues$", "[.]rep$"),
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
        "run_aspm.sh",
        "aspm.par"
      ),
      keep_patterns = c(log_patterns, "(^|/)neigenvalues$", "[.]rep$"),
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
      start_par = start_par_name,
      start_par_path = normalize_loose(check_start_par),
      staged_start_par = basename(prepared$start_par)
    ),
    extra
  )
  saveRDS(manifest, file.path(model_dir, "check_manifest.rds"), compress = "xz")
  write.csv(as.data.frame(manifest, stringsAsFactors = FALSE), file.path(model_dir, "check_manifest.csv"), row.names = FALSE)
  invisible(manifest)
}

stage_report_model_payload()

if (truthy(env("CHECK_DRY_RUN", env("CHECK_SMOKE_ONLY", "false")), FALSE)) {
  write_smoke_check_outputs()
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
  jitter_use_doitall <- truthy(env("JITTER_USE_DOITALL", "false"), FALSE)
  jitter_command <- if (isTRUE(jitter_use_doitall)) NULL else check_final_phase_command()
  write_run_manifest(list(
    jitter_seeds = paste(seeds, collapse = " "),
    jitter_cv = cv,
    jitter_slots = paste(slots, collapse = " "),
    jitter_use_doitall = jitter_use_doitall
  ))
  jitter_args <- list(
    backend = backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    seeds = seeds,
    cv = cv,
    jitter_args = list(include_slots = slots),
    par = check_start_par,
    start_par_name = "00.par",
    output_par_name = "jitter.par",
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  if (!is.null(jitter_command)) jitter_args$command <- jitter_command
  result <- do.call(mfk_run_jitter, jitter_args)
  saveRDS(result, file.path(model_dir, "jitter_runs.rds"), compress = "xz")
  try(write.csv(mfk_collect_jitter(model_dir), file.path(model_dir, "jitter-index.csv"), row.names = FALSE), silent = TRUE)

} else if (identical(check_type, "retro")) {
  peels <- as.integer(split_numbers(env("RETRO_PEELS", env("RETRO_PEEL", "1")), default = 1))
  n_mixing_periods <- as.integer(split_numbers(env("N_MIXING_PERIODS", "2"), default = 2)[[1L]])
  retro_command <- split_values(env("RETRO_COMMAND", ""))
  retro_use_doitall_raw <- tolower(trimws(env("RETRO_USE_DOITALL", "auto")))
  retro_use_doitall <- if (retro_use_doitall_raw %in% c("", "auto")) {
    file.exists(file.path(prepared$case_dir, "doitall.sh"))
  } else {
    truthy(retro_use_doitall_raw, FALSE)
  }
  retro_remove_par_files <- truthy(env("RETRO_REMOVE_PAR_FILES", "false"), FALSE)
  write_run_manifest(list(
    retro_peels = paste(peels, collapse = " "),
    n_mixing_periods = n_mixing_periods,
    retro_use_doitall = retro_use_doitall,
    retro_remove_par_files = retro_remove_par_files
  ))
  retro_args <- list(
    backend = backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    peel = peels,
    n_mixing_periods = n_mixing_periods,
    allow_new_ini_version_write = truthy(env("RETRO_ALLOW_NEW_INI_VERSION_WRITE", "false"), FALSE),
    remove_par_files = isTRUE(retro_remove_par_files),
    rewrite_par = !isTRUE(retro_use_doitall),
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  if (length(retro_command)) {
    retro_args$command <- retro_command
  } else if (!isTRUE(retro_use_doitall)) {
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
    part_dir <- file.path(model_dir, "hessian", paste0("part_", part))
    tryCatch(
      mfk_run_hessian_part(
        backend,
        input_dir = prepared$case_dir,
        output_dir = part_dir,
        part = part,
        nsplit = nsplit,
        par = check_start_par,
        frq = prepared$frq,
        compact = truthy(env("HESSIAN_COMPACT", "true"), TRUE),
        run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
      ),
      error = function(e) {
        dir.create(part_dir, recursive = TRUE, showWarnings = FALSE)
        info <- list(
          engine = "native",
          hessian_part = as.integer(part),
          nsplit = as.integer(nsplit),
          start_par = NA_integer_,
          end_par = NA_integer_,
          npars = NA_integer_,
          frq_file = basename(prepared$frq),
          program_path = program_path,
          part_dir = normalize_loose(part_dir),
          input_dir = normalize_loose(prepared$case_dir),
          input_par = basename(check_start_par),
          output_par = NA_character_,
          output_hessian = NA_character_,
          command = NA_character_,
          run_status = "model_run_failed",
          error = conditionMessage(e)
        )
        saveRDS(info, file.path(part_dir, "hessian_info.rds"), compress = "xz")
        writeLines(conditionMessage(e), file.path(part_dir, "hessian-failure.txt"), useBytes = TRUE)
        info
      }
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
    input_par = check_start_par,
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
    par = check_start_par,
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
  if (!nzchar(Sys.getenv("selftest_source_mode", ""))) {
    Sys.setenv(selftest_source_mode = env("SELFTEST_SOURCE_MODE", "last_par"))
  }
  if (!nzchar(Sys.getenv("selftest_refit_mode", ""))) {
    Sys.setenv(selftest_refit_mode = env("SELFTEST_REFIT_MODE", "last_par"))
  }
  if (nzchar(runner)) args$runner <- runner
  if (nzchar(runner_work_dir)) args$runner_work_dir <- runner_work_dir
  if ("fail_on_error" %in% names(formals(mfk_run_selftest))) {
    args$fail_on_error <- FALSE
  }
  result <- do.call(mfk_run_selftest, args)
  saveRDS(result, file.path(model_dir, "selftest_runs.rds"), compress = "xz")

} else {
  stop("Unsupported CHECK_TYPE: ", check_type, call. = FALSE)
}

enrich_check_payloads()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
write_check_status_summary(model_dir, check_type)
compact_check_outputs()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
write_check_status_summary(model_dir, check_type)
payload_index <- build_report_payloads()
write_check_payload_index(payload_index)
build_report_ready_figures()
write_attached_model_output(
  check_model_dir = model_dir,
  output_dir = output_dir,
  model_key = model_key,
  index = prepared$row,
  check_type = check_type
)
message("[checks] wrote outputs under ", model_dir)

final_summary <- tryCatch(
  readRDS(file.path(model_dir, "check-summary.rds")),
  error = function(e) NULL
)
has_failed_units <- isTRUE(final_summary$has_failures %||% FALSE)
fail_on_failed_units <- truthy(env("CHECK_FAIL_ON_FAILED_UNITS", "false"), FALSE)
if (isTRUE(fail_on_failed_units) && isTRUE(has_failed_units)) {
  n_failed <- suppressWarnings(as.integer(final_summary$n_failed %||% NA_integer_))
  if (!is.finite(n_failed)) n_failed <- NA_integer_
  message("[checks] failing task because ", check_type, " has failed diagnostic unit(s)",
          if (is.finite(n_failed)) paste0(": ", n_failed) else "")
  quit(save = "no", status = 1)
}
