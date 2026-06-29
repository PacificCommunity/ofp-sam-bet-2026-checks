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

check_doitall_command <- function(script_name = "doitall.check.sh") {
  source_script <- file.path(prepared$case_dir, "doitall.sh")
  if (!file.exists(source_script)) return(NULL)

  lines <- readLines(source_script, warn = FALSE)
  makepar <- grepl("(^|[[:space:]])-makepar([[:space:]]|$)", lines)
  if (any(makepar)) {
    first_makepar <- which(makepar)[[1L]]
    skipped <- gsub('"', '\\"', lines[[first_makepar]], fixed = TRUE)
    lines[[first_makepar]] <- paste0('echo "[checks] skipping makepar for check start par: ', skipped, '"')
  }

  out <- file.path(prepared$case_dir, script_name)
  writeLines(lines, out)
  Sys.chmod(out, mode = "0755")
  c("sh", script_name)
}

copy_if_exists <- function(from, to_dir, to_name = basename(from)) {
  if (!file.exists(from)) return(FALSE)
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  isTRUE(file.copy(from, file.path(to_dir, to_name), overwrite = TRUE, copy.date = TRUE))
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
      max_fisheries = as.integer(split_numbers(env("PLOT_MAX_FISHERIES", "18"), default = 18)[[1L]])
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
  write_run_manifest(list(jitter_seeds = paste(seeds, collapse = " "), jitter_cv = cv))
  result <- mfk_run_jitter(
    backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    seeds = seeds,
    cv = cv,
    par = prepared$start_par,
    start_par_name = "00.par",
    command = check_doitall_command() %||% mfcl_command(input_par = "00.par", output_par = "jitter.par"),
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  saveRDS(result, file.path(model_dir, "jitter_runs.rds"), compress = "xz")
  try(write.csv(mfk_collect_jitter(model_dir), file.path(model_dir, "jitter-index.csv"), row.names = FALSE), silent = TRUE)

} else if (identical(check_type, "retro")) {
  peels <- as.integer(split_numbers(env("RETRO_PEELS", env("RETRO_PEEL", "1")), default = 1))
  n_mixing_periods <- as.integer(split_numbers(env("N_MIXING_PERIODS", "2"), default = 2)[[1L]])
  write_run_manifest(list(retro_peels = paste(peels, collapse = " "), n_mixing_periods = n_mixing_periods))
  result <- mfk_run_retro(
    backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    peel = peels,
    n_mixing_periods = n_mixing_periods,
    command = mfcl_command(output_par = "retro.par"),
    run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
  )
  saveRDS(result, file.path(model_dir, "retro_runs.rds"), compress = "xz")

} else if (identical(check_type, "hessian")) {
  nsplit <- as.integer(split_numbers(env("HESSIAN_NSPLIT", env("NSPLIT", "1")), default = 1)[[1L]])
  part_values <- split_numbers(env("HESSIAN_PARTS", env("HESSIAN_PART", "")), default = seq_len(nsplit))
  parts <- as.integer(part_values)
  write_run_manifest(list(hessian_nsplit = nsplit, hessian_parts = paste(parts, collapse = " ")))
  result <- lapply(parts, function(part) {
    mfk_run_hessian_part(
      backend,
      input_dir = prepared$case_dir,
      output_dir = file.path(model_dir, "hessian", paste0("part_", part)),
      part = part,
      nsplit = nsplit,
      par = prepared$start_par,
      frq = prepared$frq,
      compact = truthy(env("HESSIAN_COMPACT", "false"), FALSE),
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
      command_fun = function(profile_row, ...) {
        mfcl_command(output_par = "profile.par", extra = mfk_quantity_profile_switch(profile_row))
      },
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
      command = mfcl_command(output_par = "profile.par"),
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

} else if (identical(check_type, "selftest")) {
  runner <- env("SELFTEST_RUNNER", "")
  if (!nzchar(runner) || !file.exists(runner)) {
    stop("Native MFCL selftest requires SELFTEST_RUNNER. This is case-specific and intentionally not hardcoded.", call. = FALSE)
  }
  reps <- as.integer(split_numbers(env("SELFTEST_REPS", env("SELFTEST_REP", "1")), default = 1))
  seed <- as.integer(split_numbers(env("SELFTEST_SEED", "20260519"), default = 20260519)[[1L]])
  write_run_manifest(list(selftest_reps = paste(reps, collapse = " "), selftest_seed = seed, selftest_runner = runner))
  result <- mfk_run_selftest(
    backend,
    input_dir = prepared$case_dir,
    model_dir = model_dir,
    reps = reps,
    seed = seed,
    par = prepared$start_par,
    runner = runner,
    run_refit = truthy(env("SELFTEST_RUN_REFIT", "true"), TRUE)
  )
  saveRDS(result, file.path(model_dir, "selftest_runs.rds"), compress = "xz")

} else {
  stop("Unsupported CHECK_TYPE: ", check_type, call. = FALSE)
}

try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
payload_index <- build_report_payloads()
write_check_payload_index(payload_index)
build_report_ready_figures()
message("[checks] wrote outputs under ", model_dir)
