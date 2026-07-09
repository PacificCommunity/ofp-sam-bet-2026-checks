source("R/model_output_adapter.R")
suppressPackageStartupMessages(library(mfclkit))

raw_check_type <- tolower(env("CHECK_MERGE_TYPE", env("CHECK_TYPE", "")))
check_type <- gsub("[-_]merge$", "", raw_check_type)
check_type <- gsub("_", "-", check_type)
if (!check_type %in% c("jitter", "profile", "retro", "selftest")) {
  stop("Unsupported merge CHECK_TYPE: ", raw_check_type, call. = FALSE)
}

message("[checks] merging split ", check_type, " jobs")

input_root <- env("MODEL_INPUT_ROOT", default_input_root())
output_dir <- env("OUTPUT_DIR", "outputs")
model_selector <- env("MODEL_SELECTOR", "")
smoke_only <- truthy(env("CHECK_SMOKE_ONLY", env("CHECK_DRY_RUN", "false")), FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

copy_file_if_exists <- function(from, to_dir, to_name = basename(from)) {
  if (!file.exists(from)) return(FALSE)
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  isTRUE(file.copy(from, file.path(to_dir, to_name), overwrite = TRUE, copy.date = TRUE))
}

copy_dir_contents_checked <- function(from, to) {
  if (!dir.exists(from)) stop("Directory not found: ", from, call. = FALSE)
  if (dir.exists(to)) {
    stop("Duplicate merged output directory: ", to, call. = FALSE)
  }
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  entries <- list.files(from, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  if (length(entries)) {
    ok <- file.copy(entries, to, recursive = TRUE, overwrite = FALSE, copy.date = TRUE)
    if (!all(ok)) stop("Could not copy all files from ", from, call. = FALSE)
  }
  normalize_loose(to)
}

bind_rows_fill_local <- function(rows) {
  rows <- rows[vapply(rows, function(x) is.data.frame(x) && nrow(x), logical(1))]
  if (!length(rows)) return(data.frame(stringsAsFactors = FALSE))
  cols <- unique(unlist(lapply(rows, names), use.names = FALSE))
  rows <- lapply(rows, function(x) {
    missing <- setdiff(cols, names(x))
    for (name in missing) x[[name]] <- NA
    x[, cols, drop = FALSE]
  })
  do.call(rbind, rows)
}

relative_to <- function(path, root = output_dir) {
  path <- normalize_loose(path)
  root <- normalize_loose(root)
  prefix <- paste0(root, "/")
  if (identical(path, root)) return(".")
  if (startsWith(path, prefix)) substring(path, nchar(prefix) + 1L) else path
}

discover_check_model_dirs <- function(root, check_type) {
  roots <- normalize_loose(root)
  roots <- roots[dir.exists(roots)]
  dirs <- unique(unlist(lapply(roots, function(one_root) {
    dirname(list.files(
      one_root,
      pattern = "^check_manifest[.]rds$",
      recursive = TRUE,
      full.names = TRUE
    ))
  }), use.names = FALSE))
  marker <- paste0("/checks/", check_type, "/")
  dirs <- dirs[grepl(marker, normalize_loose(dirs), fixed = TRUE)]
  unique(normalize_loose(dirs))
}

matches_model <- function(model_dir, selector) {
  if (!nzchar(selector)) return(TRUE)
  values <- c(basename(model_dir))
  index_file <- file.path(dirname(model_dir), "model-index.csv")
  if (file.exists(index_file)) {
    idx <- read_csv_safe(index_file)
    if (nrow(idx)) {
      row <- idx[basename(as.character(idx$model_dir %||% "")) == basename(model_dir), , drop = FALSE]
      if (!nrow(row)) row <- idx[seq_len(1L), , drop = FALSE]
      values <- c(values, unlist(row, use.names = FALSE))
    }
  }
  any(tolower(as.character(values)) == tolower(selector)) ||
    any(grepl(selector, as.character(values), fixed = TRUE))
}

copy_base_model_files <- function(source_dir, target_dir) {
  for (name in c(
    "model_payload.rds", "model_payload_manifest.json", "model_payload_manifest.csv",
    "fishery_map.R", "tag_rep_map.R", "bet.region_map.geojson", "bet.reg_scaling",
    "final.par"
  )) {
    copy_file_if_exists(file.path(source_dir, name), target_dir)
  }
  copy_existing_diagnostic_dirs(source_dir, target_dir, exclude = check_type)
}

copy_check_units <- function(source_dirs, target_dir, check_type) {
  copied <- character()
  if (identical(check_type, "jitter")) {
    for (src in source_dirs) {
      dirs <- list.dirs(file.path(src, "jitter"), recursive = FALSE, full.names = TRUE)
      dirs <- dirs[grepl("^jitter_seed_[0-9]+$", basename(dirs))]
      for (dir in dirs) copied <- c(copied, copy_dir_contents_checked(dir, file.path(target_dir, "jitter", basename(dir))))
    }
  } else if (identical(check_type, "retro")) {
    for (src in source_dirs) {
      dirs <- list.dirs(file.path(src, "retro"), recursive = FALSE, full.names = TRUE)
      dirs <- dirs[grepl("^peel_[0-9]+$", basename(dirs))]
      for (dir in dirs) copied <- c(copied, copy_dir_contents_checked(dir, file.path(target_dir, "retro", basename(dir))))
    }
  } else if (identical(check_type, "profile")) {
    for (src in source_dirs) {
      profile_roots <- list.dirs(file.path(src, "profile"), recursive = FALSE, full.names = TRUE)
      for (profile_root in profile_roots) {
        dirs <- list.dirs(profile_root, recursive = FALSE, full.names = TRUE)
        dirs <- dirs[grepl("^scalar_", basename(dirs))]
        for (dir in dirs) {
          copied <- c(copied, copy_dir_contents_checked(
            dir,
            file.path(target_dir, "profile", basename(profile_root), basename(dir))
          ))
        }
      }
    }
  } else if (identical(check_type, "selftest")) {
    selftest_rows <- list()
    for (src in source_dirs) {
      src_root <- file.path(src, "selftest")
      if (!dir.exists(src_root)) next
      for (top in c("sim", "inputs", "truth_eval", "refit", "recovery")) {
        top_dir <- file.path(src_root, top)
        if (!dir.exists(top_dir)) next
        children <- list.dirs(top_dir, recursive = FALSE, full.names = TRUE)
        for (child in children) {
          copied <- c(copied, copy_dir_contents_checked(child, file.path(target_dir, "selftest", top, basename(child))))
        }
      }
      truth_dir <- file.path(src_root, "truth")
      if (dir.exists(truth_dir) && !dir.exists(file.path(target_dir, "selftest", "truth"))) {
        copied <- c(copied, copy_dir_contents_checked(truth_dir, file.path(target_dir, "selftest", "truth")))
      }
      files <- list.files(src_root, all.files = TRUE, no.. = TRUE, full.names = TRUE)
      files <- files[file.info(files)$isdir %in% FALSE]
      files <- files[!basename(files) %in% c("selftest_runs.rds", "selftest_runs.csv")]
      for (file in files) {
        target_file <- file.path(target_dir, "selftest", basename(file))
        if (!file.exists(target_file)) {
          if (!copy_file_if_exists(file, file.path(target_dir, "selftest"))) {
            stop("Could not copy selftest file: ", file, call. = FALSE)
          }
          copied <- c(copied, target_file)
        }
      }
      runs_file <- file.path(src_root, "selftest_runs.rds")
      if (file.exists(runs_file)) {
        dat <- tryCatch(readRDS(runs_file), error = function(e) NULL)
        if (is.data.frame(dat)) selftest_rows[[length(selftest_rows) + 1L]] <- dat
      }
    }
    merged_runs <- bind_rows_fill_local(selftest_rows)
    if (nrow(merged_runs)) {
      dir.create(file.path(target_dir, "selftest"), recursive = TRUE, showWarnings = FALSE)
      saveRDS(merged_runs, file.path(target_dir, "selftest", "selftest_runs.rds"), compress = "xz")
      write.csv(merged_runs, file.path(target_dir, "selftest", "selftest_runs.csv"), row.names = FALSE)
    }
  }
  if (!length(copied)) {
    warning("No ", check_type, " unit outputs found to merge; writing summary-only merge.", call. = FALSE)
  }
  copied
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
  if ("total_nll" %in% names(dat)) {
    total_nll <- suppressWarnings(as.numeric(dat$total_nll))
    success <- success & is.finite(total_nll)
  }
  success
}

collect_check_unit_status <- function(model_dir, check_type, source_dirs = character()) {
  out <- tryCatch({
    if (identical(check_type, "jitter")) {
      mfclkit::mfk_collect_jitter(model_dir)
    } else if (identical(check_type, "retro")) {
      mfclkit::mfk_collect_retro(model_dir)
    } else if (identical(check_type, "profile")) {
      roots <- list.dirs(file.path(model_dir, "profile"), recursive = FALSE, full.names = TRUE)
      bind_rows_fill_local(lapply(roots, mfclkit::mfk_read_profile_points))
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
      found
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
  if (!is.data.frame(out) || !nrow(out)) {
    summaries <- lapply(source_dirs, function(src) {
      path <- file.path(src, "check-summary.csv")
      if (file.exists(path)) read_csv_safe(path) else data.frame(stringsAsFactors = FALSE)
    })
    out <- bind_rows_fill_local(summaries)
  }
  if (!is.data.frame(out)) out <- data.frame(stringsAsFactors = FALSE)
  if (nrow(out)) {
    out$check_type <- check_type
    success <- check_status_success(out)
    if (length(success) != nrow(out)) success <- rep(FALSE, nrow(out))
    out$success <- success
  }
  out
}

write_check_status_summary <- function(model_dir, check_type, source_dirs = character()) {
  units <- collect_check_unit_status(model_dir, check_type, source_dirs)
  if (nrow(units)) {
    write.csv(units, file.path(model_dir, "check-unit-status.csv"), row.names = FALSE)
    saveRDS(units, file.path(model_dir, "check-unit-status.rds"), compress = "xz")
  }
  source_summaries <- bind_rows_fill_local(lapply(source_dirs, function(src) {
    path <- file.path(src, "check-summary.csv")
    if (!file.exists(path)) return(data.frame(stringsAsFactors = FALSE))
    dat <- read_csv_safe(path)
    if (!nrow(dat)) return(dat)
    dat$source_model_dir <- normalize_loose(src)
    dat
  }))
  if (nrow(source_summaries)) {
    source_summaries$success <- check_status_success(source_summaries)
    write.csv(source_summaries, file.path(model_dir, "check-source-status.csv"), row.names = FALSE)
    saveRDS(source_summaries, file.path(model_dir, "check-source-status.rds"), compress = "xz")
  }
  n_units <- nrow(units)
  n_success <- if (n_units) sum(units$success %in% TRUE, na.rm = TRUE) else 0L
  n_failed <- if (n_units) sum(!(units$success %in% TRUE), na.rm = TRUE) else 0L
  n_source_units <- nrow(source_summaries)
  n_source_failed <- if (n_source_units) sum(!(source_summaries$success %in% TRUE), na.rm = TRUE) else 0L
  requires_all_units <- check_type %in% c("hessian", "profile")
  total_failed <- n_failed + n_source_failed
  merge_status <- if (!n_units && !n_source_units) {
    "no_units"
  } else if (requires_all_units && total_failed > 0L) {
    "incomplete"
  } else if (total_failed > 0L) {
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
    has_failures = total_failed > 0L,
    n_source_model_dirs = length(source_dirs),
    n_source_units = n_source_units,
    n_source_failed = n_source_failed,
    requires_all_units = requires_all_units,
    all_required_units_successful = !requires_all_units || ((n_units > 0L || n_source_units > 0L) && total_failed == 0L),
    merge_status = merge_status,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  write.csv(summary, file.path(model_dir, "check-summary.csv"), row.names = FALSE)
  saveRDS(as.list(summary), file.path(model_dir, "check-summary.rds"), compress = "xz")
  invisible(summary)
}

check_report_figure_keys <- function(check_type) {
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
    selftest = c(
      "figure:selftest-recovery",
      "figure:selftest-simulation",
      "figure:selftest-parameter-recovery"
    ),
    character()
  )
}

write_check_report_selection <- function(report_dir, check_type) {
  keys <- check_report_figure_keys(check_type)
  if (!length(keys) || !requireNamespace("jsonlite", quietly = TRUE)) {
    return(NULL)
  }
  figure_ids <- sub("^figure:", "", keys)
  labels <- tools::toTitleCase(gsub("-", " ", figure_ids, fixed = TRUE))
  section <- switch(
    check_type,
    jitter = "Jitter",
    retro = "Retro",
    selftest = "Self-test",
    profile = "Profile",
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
    source = paste0("ofp-sam-bet-2026-checks:", check_type, "-merge"),
    analysis = list(),
    inputs = list(),
    items = items
  )
  path <- file.path(report_dir, "check-report-selection.json")
  jsonlite::write_json(selection, path, dataframe = "rows", auto_unbox = TRUE, pretty = TRUE, null = "null")
  write.csv(items, sub("[.]json$", ".csv", path), row.names = FALSE)
  path
}

build_report_ready_figures <- function(model_dir, output_dir, check_type, model_key) {
  if (!truthy(env("CHECK_BUILD_REPORT_FIGURES", "true"), TRUE)) return(invisible(NULL))
  if (!requireNamespace("mfclshiny", quietly = TRUE) ||
      !"build_app_report_figures" %in% getNamespaceExports("mfclshiny")) {
    warning("mfclshiny::build_app_report_figures is not available; skipping report-ready figures.", call. = FALSE)
    return(invisible(NULL))
  }
  out <- file.path(output_dir, "report-ready-checks", check_type, model_key)
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  selection_file <- write_check_report_selection(out, check_type)
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

enrich_merged_check_payloads <- function() {
  if (!truthy(env("CHECK_ENRICH_PAYLOADS", "true"), TRUE)) return(invisible(data.frame()))
  if (identical(check_type, "jitter")) {
    seed_dirs <- list.dirs(file.path(model_dir, "jitter"), recursive = FALSE, full.names = TRUE)
    seed_dirs <- seed_dirs[grepl("^jitter_seed_[0-9]+$", basename(seed_dirs))]
    if (!length(seed_dirs)) return(invisible(data.frame()))
    tool_env <- mfclshiny_payload_tool_env("jitter")
    rows <- lapply(seed_dirs, function(seed_dir) {
      payload <- tool_env$mp_build_jitter_payload(seed_dir)
      out_file <- file.path(seed_dir, "jitter_result.rds")
      saveRDS(payload, out_file, compress = "xz")
      data.frame(payload_role = "jitter_result", folder = normalize_loose(seed_dir),
                 payload = normalize_loose(out_file), stringsAsFactors = FALSE)
    })
    return(invisible(bind_rows_fill_local(rows)))
  }
  if (identical(check_type, "profile")) {
    scalar_dirs <- list.dirs(file.path(model_dir, "profile"), recursive = TRUE, full.names = TRUE)
    scalar_dirs <- scalar_dirs[grepl("^scalar_", basename(scalar_dirs))]
    missing <- scalar_dirs[!file.exists(file.path(scalar_dirs, "profile_payload.rds"))]
    if (length(missing)) {
      tool_env <- mfclshiny_payload_tool_env("profile")
      for (scalar_dir in missing) {
        payload <- tool_env$mp_build_profile_payload(scalar_dir)
        saveRDS(payload, file.path(scalar_dir, "profile_payload.rds"), compress = "xz")
      }
    }
  }
  invisible(data.frame())
}

compact_merged_check_outputs <- function() {
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
  }

  out <- bind_rows_fill_local(deleted)
  compact_prune_empty_dirs(model_dir)
  if (nrow(out)) {
    out$removed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    write.csv(out, file.path(model_dir, "check-output-cleanup.csv"), row.names = FALSE)
    saveRDS(out, file.path(model_dir, "check-output-cleanup.rds"), compress = "xz")
    message("[checks] compacted merged ", check_type, " output: removed ", nrow(out), " raw/intermediate files")
  }
  invisible(out)
}

source_model_dirs <- discover_check_model_dirs(input_root, check_type)
source_model_dirs <- source_model_dirs[vapply(source_model_dirs, matches_model, logical(1), selector = model_selector)]
if (!length(source_model_dirs)) {
  stop("No ", check_type, " check model folders found under ", input_root, call. = FALSE)
}

model_key <- gsub("[^A-Za-z0-9_.-]+", "_", basename(source_model_dirs[[1L]]))
if (!nzchar(model_key)) model_key <- "model"
model_dir <- file.path(output_dir, "checks", check_type, model_key)
if (dir.exists(model_dir)) unlink(model_dir, recursive = TRUE, force = TRUE)
dir.create(model_dir, recursive = TRUE, showWarnings = FALSE)

copy_base_model_files(source_model_dirs[[1L]], model_dir)
copied <- copy_check_units(source_model_dirs, model_dir, check_type)

if (isTRUE(smoke_only)) {
  write.csv(
    data.frame(
      check_type = check_type,
      model_key = model_key,
      n_source_model_dirs = length(source_model_dirs),
      n_copied_paths = length(copied),
      smoke = TRUE,
      stringsAsFactors = FALSE
    ),
    file.path(model_dir, paste0(check_type, "-smoke-merge.csv")),
    row.names = FALSE
  )
} else if (identical(check_type, "jitter")) {
  try(write.csv(mfclkit::mfk_collect_jitter(model_dir), file.path(model_dir, "jitter-index.csv"), row.names = FALSE), silent = TRUE)
} else if (identical(check_type, "retro")) {
  try(write.csv(mfclkit::mfk_collect_retro(model_dir), file.path(model_dir, "retro-index.csv"), row.names = FALSE), silent = TRUE)
} else if (identical(check_type, "profile")) {
  profile_roots <- list.dirs(file.path(model_dir, "profile"), recursive = FALSE, full.names = TRUE)
  points <- bind_rows_fill_local(lapply(profile_roots, mfclkit::mfk_read_profile_points))
  write.csv(points, file.path(model_dir, "profile-points.csv"), row.names = FALSE)
  if (nrow(points)) {
    write.csv(mfclkit::mfk_profile_conflict_metrics(points), file.path(model_dir, "profile-qc.csv"), row.names = FALSE)
  }
}
write_check_status_summary(model_dir, check_type, source_model_dirs)

rows <- list()
for (source_parent in unique(dirname(source_model_dirs))) {
  index_file <- file.path(source_parent, "model-index.csv")
  if (!file.exists(index_file)) next
  dat <- read_csv_safe(index_file)
  if (!nrow(dat)) next
  dat$source_index_file <- normalize_loose(index_file)
  rows[[length(rows) + 1L]] <- dat
}
index <- bind_rows_fill_local(rows)
if (!nrow(index)) {
  index <- data.frame(
    check_type = check_type,
    model_key = model_key,
    parent_model_key = model_key,
    model_label = model_key,
    step_id = model_key,
    model_dir = basename(model_dir),
    model_folder = basename(model_dir),
    check_model_dir = normalize_loose(model_dir),
    check_model_relative_dir = file.path("checks", check_type, basename(model_dir)),
    payload_role = "check_model_root",
    stringsAsFactors = FALSE
  )
}
index$check_type <- check_type
index$model_dir <- basename(model_dir)
index$model_folder <- basename(model_dir)
index$check_model_dir <- normalize_loose(model_dir)
index$check_model_relative_dir <- file.path("checks", check_type, basename(model_dir))
write.csv(index, file.path(dirname(model_dir), "model-index.csv"), row.names = FALSE)
write.csv(index, file.path(dirname(model_dir), "check-model-index.csv"), row.names = FALSE)
write.csv(index, file.path(output_dir, "checks-index.csv"), row.names = FALSE)

manifest <- data.frame(
  check_type = check_type,
  model_key = model_key,
  model_dir = normalize_loose(model_dir),
  source_model_dirs = paste(source_model_dirs, collapse = " "),
  n_source_model_dirs = length(source_model_dirs),
  copied_paths = paste(copied, collapse = " "),
  stringsAsFactors = FALSE
)
write.csv(manifest, file.path(model_dir, "check_manifest.csv"), row.names = FALSE)
saveRDS(as.list(manifest), file.path(model_dir, "check_manifest.rds"), compress = "xz")

enrich_merged_check_payloads()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
write_check_status_summary(model_dir, check_type, source_model_dirs)
compact_merged_check_outputs()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
write_check_status_summary(model_dir, check_type, source_model_dirs)
if (requireNamespace("mfclshiny", quietly = TRUE)) {
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
}
if (!isTRUE(smoke_only)) build_report_ready_figures(model_dir, output_dir, check_type, model_key)
write_attached_model_output(
  check_model_dir = model_dir,
  output_dir = output_dir,
  model_key = model_key,
  index = index,
  check_type = check_type,
  source_check_dirs = source_model_dirs
)
message("[checks] merged ", check_type, " outputs under ", model_dir)

final_summary <- tryCatch(
  readRDS(file.path(model_dir, "check-summary.rds")),
  error = function(e) NULL
)
requires_all_units <- isTRUE(final_summary$requires_all_units %||% FALSE)
all_required_ok <- isTRUE(final_summary$all_required_units_successful %||% FALSE)
if (isTRUE(requires_all_units) && !isTRUE(all_required_ok)) {
  merge_status <- as.character(final_summary$merge_status %||% "incomplete")
  message("[checks] failing ", check_type, " merge because required unit(s) are incomplete: ", merge_status)
  quit(save = "no", status = 1)
}
