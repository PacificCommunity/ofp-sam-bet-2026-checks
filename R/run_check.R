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
    command = mfcl_command(input_par = "00.par", output_par = "jitter.par"),
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
message("[checks] wrote outputs under ", model_dir)
