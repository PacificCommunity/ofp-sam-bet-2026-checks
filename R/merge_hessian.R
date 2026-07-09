source("R/model_output_adapter.R")
suppressPackageStartupMessages(library(mfclkit))

message("[checks] merging split Hessian parts")

input_root <- env("MODEL_INPUT_ROOT", default_input_root())
output_dir <- env("OUTPUT_DIR", "outputs")
work_dir <- env("WORK_DIR", "work")
model_selector <- env("MODEL_SELECTOR", "")
program_path <- env("PROGRAM_PATH", "/home/mfcl/mfclo64")
smoke_only <- truthy(env("CHECK_SMOKE_ONLY", env("CHECK_DRY_RUN", "false")), FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)

copy_file_if_exists <- function(from, to_dir, to_name = basename(from)) {
  if (!file.exists(from)) return(FALSE)
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  isTRUE(file.copy(from, file.path(to_dir, to_name), overwrite = TRUE, copy.date = TRUE))
}

copy_dir_contents <- function(from, to) {
  if (!dir.exists(from)) stop("Directory not found: ", from, call. = FALSE)
  if (dir.exists(to)) unlink(to, recursive = TRUE, force = TRUE)
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  entries <- list.files(from, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  if (length(entries)) {
    ok <- file.copy(entries, to, recursive = TRUE, overwrite = TRUE, copy.date = TRUE)
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
    check_type = "hessian",
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

compact_hessian_merge_outputs <- function() {
  if (!check_compact_outputs_enabled()) return(invisible(data.frame()))

  log_patterns <- c("(^|/).*log($|[.])", "(^|/)mfcl.*[.]txt$")
  keep_matrix <- truthy(env("HESSIAN_KEEP_MATRIX", "false"), FALSE)
  hessian_keep_patterns <- c(log_patterns, "(^|/)neigenvalues$")
  if (isTRUE(keep_matrix)) {
    hessian_keep_patterns <- c(hessian_keep_patterns, "[.]hes(_[0-9]+)?$", "(^|/)parall_hess$")
  }

  deleted <- list(
    compact_prune_files(
      hessian_dir,
      keep_names = c("hessian_info.rds", "mfcl_stitch_log.txt", "mfcl_eigen_log.txt"),
      keep_patterns = hessian_keep_patterns,
      recursive = TRUE
    ),
    compact_prune_files(
      model_dir,
      keep_names = c(
        "model_payload.rds", "model_payload_manifest.json", "model_payload_manifest.csv",
        "fishery_map.R", "tag_rep_map.R", "bet.region_map.geojson", "bet.reg_scaling",
        "check_manifest.csv", "check_manifest.rds", "hessian_merge.rds",
        "hessian-part-status.csv", "hessian-part-status.rds",
        "check-unit-status.csv", "check-unit-status.rds",
        "check-summary.csv", "check-summary.rds",
        "model-index.csv", "check-model-index.csv", "mfclkit_diagnostics.rds",
        "mfclkit_diagnostics.csv", "check-output-cleanup.csv", "check-output-cleanup.rds"
      ),
      keep_patterns = c("(^|/)hessian/", "(^|/).*index[.]csv$", log_patterns),
      recursive = FALSE
    )
  )
  out <- bind_rows_fill_local(deleted)
  compact_prune_empty_dirs(model_dir)
  if (nrow(out)) {
    out$removed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    write.csv(out, file.path(model_dir, "check-output-cleanup.csv"), row.names = FALSE)
    saveRDS(out, file.path(model_dir, "check-output-cleanup.rds"), compress = "xz")
    message("[checks] compacted merged Hessian output: removed ", nrow(out), " raw/intermediate files")
  }
  invisible(out)
}

discover_hessian_model_dirs <- function(root) {
  roots <- normalize_loose(root)
  roots <- roots[dir.exists(roots)]
  dirs <- unique(unlist(lapply(roots, function(one_root) {
    dirname(list.files(
      one_root,
      pattern = "^hessian_info[.]rds$",
      recursive = TRUE,
      full.names = TRUE
    ))
  }), use.names = FALSE))
  dirs <- dirs[grepl("/hessian/part_[0-9]+$", normalize_loose(dirs))]
  model_dirs <- normalize_loose(dirname(dirname(dirs)))
  unique(model_dirs)
}

hessian_part_source_table <- function(model_dirs) {
  part_dirs <- unique(unlist(lapply(model_dirs, function(src) {
    list.dirs(file.path(src, "hessian"), recursive = FALSE, full.names = TRUE)
  }), use.names = FALSE))
  part_dirs <- part_dirs[grepl("^part_[0-9]+$", basename(part_dirs))]
  if (!length(part_dirs)) {
    return(data.frame(stringsAsFactors = FALSE))
  }

  normalized <- normalize_loose(part_dirs)
  part_numbers <- suppressWarnings(as.integer(sub("^part_", "", basename(part_dirs))))
  out <- data.frame(
    part_number = part_numbers,
    part_dir = normalized,
    source_model_dir = normalize_loose(dirname(dirname(part_dirs))),
    priority = ifelse(
      grepl("/checks/hessian/", normalized, fixed = TRUE),
      0L,
      ifelse(grepl("/models/", normalized, fixed = TRUE), 1L, 2L)
    ),
    path_length = nchar(normalized),
    stringsAsFactors = FALSE
  )
  out <- out[is.finite(out$part_number), , drop = FALSE]
  out <- out[order(out$part_number, out$priority, out$path_length, out$part_dir), , drop = FALSE]
  duplicated_parts <- unique(out$part_number[duplicated(out$part_number)])
  if (length(duplicated_parts)) {
    message(
      "[checks] duplicate Hessian part directories found for part(s) ",
      paste(duplicated_parts, collapse = ", "),
      "; using the canonical copy for each part"
    )
    out <- out[!duplicated(out$part_number), , drop = FALSE]
  }
  rownames(out) <- NULL
  out
}

hessian_part_status_table <- function(hessian_dir, expected_nsplit = NA_integer_) {
  part_dirs <- list.dirs(hessian_dir, recursive = FALSE, full.names = TRUE)
  part_dirs <- part_dirs[grepl("^part_[0-9]+$", basename(part_dirs))]
  part_numbers <- suppressWarnings(as.integer(sub("^part_", "", basename(part_dirs))))
  keep <- is.finite(part_numbers)
  part_dirs <- part_dirs[keep]
  part_numbers <- part_numbers[keep]
  observed_parts <- sort(unique(part_numbers))
  expected_parts <- if (is.finite(expected_nsplit) && expected_nsplit > 0L) {
    seq_len(expected_nsplit)
  } else {
    observed_parts
  }
  if (!length(expected_parts)) expected_parts <- integer()
  rows <- lapply(expected_parts, function(part) {
    dir <- part_dirs[part_numbers == part]
    dir <- if (length(dir)) dir[[1L]] else file.path(hessian_dir, paste0("part_", part))
    info_file <- file.path(dir, "hessian_info.rds")
    hinfo <- if (file.exists(info_file)) tryCatch(readRDS(info_file), error = function(e) NULL) else NULL
    hes_files <- if (dir.exists(dir)) list.files(dir, pattern = "\\.hes$", full.names = FALSE) else character()
    output_hessian <- as.character(hinfo$output_hessian %||% NA_character_)
    if ((!length(output_hessian) || is.na(output_hessian) || !nzchar(output_hessian)) && length(hes_files)) {
      output_hessian <- hes_files[[1L]]
    }
    has_hessian_file <- length(hes_files) > 0L ||
      (!is.na(output_hessian) && nzchar(output_hessian) && file.exists(file.path(dir, output_hessian)))
    run_status <- as.character(hinfo$run_status %||% if (file.exists(info_file)) "unknown" else "missing")
    missing <- !dir.exists(dir) || !file.exists(info_file)
    success <- !missing && identical(run_status, "completed") && isTRUE(has_hessian_file)
    data.frame(
      check_type = "hessian",
      unit = paste0("part_", part),
      part = as.integer(part),
      run_status = run_status,
      run_completed = !missing && !identical(run_status, "model_run_failed"),
      output_hessian = output_hessian,
      has_hessian_file = isTRUE(has_hessian_file),
      success = isTRUE(success),
      missing = isTRUE(missing),
      failure_reason = as.character(hinfo$error %||% if (missing) "missing Hessian part metadata" else ""),
      folder = normalize_loose(dir),
      stringsAsFactors = FALSE
    )
  })
  observed_only <- setdiff(observed_parts, expected_parts)
  if (length(observed_only)) {
    rows <- c(rows, lapply(observed_only, function(part) {
      dir <- part_dirs[part_numbers == part][[1L]]
      hinfo <- tryCatch(readRDS(file.path(dir, "hessian_info.rds")), error = function(e) NULL)
      hes_files <- list.files(dir, pattern = "\\.hes$", full.names = FALSE)
      output_hessian <- as.character(hinfo$output_hessian %||% if (length(hes_files)) hes_files[[1L]] else NA_character_)
      data.frame(
        check_type = "hessian",
        unit = paste0("part_", part),
        part = as.integer(part),
        run_status = as.character(hinfo$run_status %||% "unknown"),
        run_completed = !identical(hinfo$run_status, "model_run_failed"),
        output_hessian = output_hessian,
        has_hessian_file = length(hes_files) > 0L,
        success = FALSE,
        missing = FALSE,
        failure_reason = "unexpected Hessian part outside expected nsplit",
        folder = normalize_loose(dir),
        stringsAsFactors = FALSE
      )
    }))
  }
  bind_rows_fill_local(rows)
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

source_model_dirs <- discover_hessian_model_dirs(input_root)
source_model_dirs <- source_model_dirs[vapply(source_model_dirs, matches_model, logical(1), selector = model_selector)]
part_table <- hessian_part_source_table(source_model_dirs)
base_model_dir <- if (nrow(part_table)) {
  part_table$source_model_dir[[1L]]
} else if (length(source_model_dirs)) {
  source_model_dirs[[1L]]
} else {
  NA_character_
}
source_model_dirs <- unique(c(source_model_dirs, part_table$source_model_dir))
source_model_dirs <- source_model_dirs[!is.na(source_model_dirs) & nzchar(source_model_dirs)]

model_key <- if (!is.na(base_model_dir) && nzchar(base_model_dir)) {
  gsub("[^A-Za-z0-9_.-]+", "_", basename(base_model_dir))
} else {
  gsub("[^A-Za-z0-9_.-]+", "_", model_selector)
}
if (!nzchar(model_key)) model_key <- "model"
model_dir <- file.path(output_dir, "checks", "hessian", model_key)
hessian_dir <- file.path(model_dir, "hessian")
dir.create(hessian_dir, recursive = TRUE, showWarnings = FALSE)

if (!is.na(base_model_dir) && dir.exists(base_model_dir)) {
  for (name in c(
    "model_payload.rds", "model_payload_manifest.json", "model_payload_manifest.csv",
    "fishery_map.R", "tag_rep_map.R", "bet.region_map.geojson", "bet.reg_scaling",
    "final.par"
  )) {
    copy_file_if_exists(file.path(base_model_dir, name), model_dir)
  }
  copy_existing_diagnostic_dirs(base_model_dir, model_dir, exclude = "hessian")

  case_files <- unique(unlist(lapply(c(
    "[.]frq$",
    "[.]ini$",
    "[.]tag$",
    "[.]age_length$",
    "[.]dep$",
    "[.]dp2$",
    "^mfcl[.]cfg$",
    "^depgrad[.]rpt$",
    "^Hess[.]rpt$"
  ), function(pattern) {
    list.files(base_model_dir, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
  }), use.names = FALSE))
  for (case_file in case_files) {
    copy_file_if_exists(case_file, model_dir)
  }
}

part_sources <- part_table$part_dir
part_numbers <- part_table$part_number

for (part_dir in part_sources) {
  copy_dir_contents(part_dir, file.path(hessian_dir, basename(part_dir)))
}

expected_nsplit <- suppressWarnings(as.integer(env("HESSIAN_NSPLIT", NA_character_)))
part_status <- hessian_part_status_table(hessian_dir, expected_nsplit = expected_nsplit)
if (nrow(part_status)) {
  write.csv(part_status, file.path(model_dir, "hessian-part-status.csv"), row.names = FALSE)
  write.csv(part_status, file.path(model_dir, "check-unit-status.csv"), row.names = FALSE)
  saveRDS(part_status, file.path(model_dir, "hessian-part-status.rds"), compress = "xz")
  saveRDS(part_status, file.path(model_dir, "check-unit-status.rds"), compress = "xz")
}
n_units <- nrow(part_status)
n_success <- if (n_units) sum(part_status$success %in% TRUE, na.rm = TRUE) else 0L
n_failed <- if (n_units) sum(!(part_status$success %in% TRUE), na.rm = TRUE) else 0L
missing <- if (n_units && "missing" %in% names(part_status)) {
  part_status$part[part_status$missing %in% TRUE]
} else {
  integer()
}
requested_run_stitch <- truthy(env("HESSIAN_MERGE_RUN", if (isTRUE(smoke_only)) "false" else "true"), TRUE)
requested_run_eigen <- truthy(env("HESSIAN_MERGE_EIGEN", if (isTRUE(smoke_only)) "false" else "true"), TRUE)
complete_for_stitch <- n_units > 0L && n_failed == 0L
run_stitch <- requested_run_stitch && complete_for_stitch
run_eigen <- requested_run_eigen && complete_for_stitch
merge_status <- if (!n_units) {
  "no_units"
} else if (!complete_for_stitch) {
  "incomplete_parts"
} else {
  "complete"
}

incomplete_info <- function(status, reliability, reason) {
  list(
    schema = "ofp-sam.checks.hessian_merge_status.v1",
    meta = list(
      hessian_dir = normalize_loose(hessian_dir),
      root_name = model_key,
      model_key = model_key,
      parts = part_numbers,
      n_parts = length(part_numbers),
      expected_nsplit = expected_nsplit,
      n_units = n_units,
      n_success = n_success,
      n_failed = n_failed,
      missing_parts = missing,
      merge_status = status,
      failure_reason = reason
    ),
    stitch = list(
      run = FALSE,
      stitched_hessian_file = NA_character_
    ),
    eigen = list(
      run = FALSE,
      n_negative_eigenvalues = NA_integer_,
      n_total_eigenvalues = NA_integer_,
      hessian_status = status,
      reliability = reliability
    ),
    diagnostics = list(
      summary = list(
        hessian_ok = FALSE,
        pdh = list(is_pdh = NA),
        spd = NA
      ),
      part_status = part_status
    ),
    smoke = isTRUE(smoke_only),
    run_stitch = requested_run_stitch,
    run_eigen = requested_run_eigen
  )
}

info <- if (isTRUE(smoke_only)) {
  incomplete_info("smoke_only", "SMOKE", "CHECK_SMOKE_ONLY=true")
} else if (!complete_for_stitch) {
  incomplete_info("incomplete_parts", "FAILED_PARTS", "One or more Hessian parts failed or are missing.")
} else {
  tryCatch(
    mfclkit::mfk_stitch_native_hessian(
      model_dir,
      model_dir = model_dir,
      program_path = program_path,
      run = run_stitch,
      eigen = run_eigen,
      require_complete = TRUE,
      fail_on_command_error = FALSE,
      run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
    ),
    error = function(e) {
      merge_status <<- "stitch_failed"
      incomplete_info("stitch_failed", "STITCH_FAILED", conditionMessage(e))
    }
  )
}
saveRDS(info, file.path(model_dir, "hessian_merge.rds"), compress = "xz")
saveRDS(info, file.path(hessian_dir, "hessian_info.rds"), compress = "xz")

summary <- data.frame(
  check_type = "hessian",
  model_key = model_key,
  n_units = n_units,
  n_success = n_success,
  n_failed = n_failed,
  has_failures = n_failed > 0L,
  n_source_model_dirs = length(source_model_dirs),
  requires_all_units = TRUE,
  all_required_units_successful = n_units > 0L && n_failed == 0L,
  merge_status = merge_status,
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  stringsAsFactors = FALSE
)
write.csv(summary, file.path(model_dir, "check-summary.csv"), row.names = FALSE)
saveRDS(as.list(summary), file.path(model_dir, "check-summary.rds"), compress = "xz")

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
    check_type = "hessian",
    model_key = model_key,
    parent_model_key = model_key,
    model_label = model_key,
    step_id = model_key,
    model_dir = basename(model_dir),
    model_folder = basename(model_dir),
    check_model_dir = normalize_loose(model_dir),
    check_model_relative_dir = file.path("checks", "hessian", basename(model_dir)),
    payload_role = "check_model_root",
    stringsAsFactors = FALSE
  )
}
index$check_type <- "hessian"
index$model_dir <- basename(model_dir)
index$model_folder <- basename(model_dir)
index$check_model_dir <- normalize_loose(model_dir)
index$check_model_relative_dir <- file.path("checks", "hessian", basename(model_dir))
write.csv(index, file.path(dirname(model_dir), "model-index.csv"), row.names = FALSE)
write.csv(index, file.path(dirname(model_dir), "check-model-index.csv"), row.names = FALSE)
write.csv(index, file.path(output_dir, "checks-index.csv"), row.names = FALSE)

manifest <- data.frame(
  check_type = "hessian",
  model_key = model_key,
  model_dir = normalize_loose(model_dir),
  hessian_dir = normalize_loose(hessian_dir),
  n_parts = length(part_numbers),
  n_units = n_units,
  n_success = n_success,
  n_failed = n_failed,
  requires_all_units = TRUE,
  all_required_units_successful = n_units > 0L && n_failed == 0L,
  merge_status = merge_status,
  parts = paste(part_numbers, collapse = " "),
  run_stitch = run_stitch,
  run_eigen = run_eigen,
  requested_run_stitch = requested_run_stitch,
  requested_run_eigen = requested_run_eigen,
  stringsAsFactors = FALSE
)
write.csv(manifest, file.path(model_dir, "check_manifest.csv"), row.names = FALSE)
saveRDS(as.list(manifest), file.path(model_dir, "check_manifest.rds"), compress = "xz")

try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
compact_hessian_merge_outputs()
try(mfclkit::mfk_collect_diagnostics(model_dir, write_index = TRUE), silent = TRUE)
write_attached_model_output(
  check_model_dir = model_dir,
  output_dir = output_dir,
  model_key = model_key,
  index = index,
  check_type = "hessian",
  source_check_dirs = source_model_dirs
)
message("[checks] merged Hessian parts under ", model_dir)

if (!identical(merge_status, "complete")) {
  message("[checks] merged Hessian outputs with incomplete partition status: ", merge_status)
}
