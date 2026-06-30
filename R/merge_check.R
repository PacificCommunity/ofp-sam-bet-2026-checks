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
  dirs <- dirs[file.exists(file.path(dirs, "model_payload.rds"))]
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
    stop("No ", check_type, " unit outputs found to merge.", call. = FALSE)
  }
  copied
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

if (identical(check_type, "jitter")) {
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

try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
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
build_report_ready_figures(model_dir, output_dir, check_type, model_key)
message("[checks] merged ", check_type, " outputs under ", model_dir)
