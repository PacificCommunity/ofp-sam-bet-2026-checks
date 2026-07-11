source("R/model_output_adapter.R")

message("[checks] attaching completed check outputs to model bundle")

input_root <- env("MODEL_INPUT_ROOT", default_input_root())
output_dir <- env("OUTPUT_DIR", "outputs")
model_selector <- env("MODEL_SELECTOR", "")
base_input_job <- env("MODEL_BASE_INPUT_JOB", env("BASE_MODEL_JOB", ""))
check_input_jobs <- split_values(env("CHECK_INPUT_JOBS", ""))
attach_check_types <- split_values(env("ATTACH_CHECK_TYPES", ""))
attach_output_mode <- normalize_attached_output_mode()
original_base_input_job <- env("MODEL_ORIGINAL_BASE_INPUT_JOB", base_input_job)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

normalize_check_type <- function(value) {
  value <- gsub("-", "_", tolower(as.character(value %||% "")))
  sub("_merge$", "", value)
}

check_status_file_names <- function() {
  c(
    "check-unit-status.csv", "check-unit-status.rds",
    "check-summary.csv", "check-summary.rds",
    "check-source-status.csv", "check-source-status.rds",
    "check_manifest.csv", "check_manifest.rds"
  )
}

check_status_files <- function(model_dir) {
  paths <- file.path(model_dir, check_status_file_names())
  paths[file.exists(paths)]
}

has_check_status_ledger <- function(model_dir) {
  any(file.exists(file.path(model_dir, c(
    "check-unit-status.csv", "check-unit-status.rds",
    "check-summary.csv", "check-summary.rds"
  ))))
}

status_check_types <- function(model_dir) {
  values <- character()
  csv_files <- file.path(model_dir, c(
    "check-unit-status.csv", "check-summary.csv", "check_manifest.csv"
  ))
  for (path in csv_files[file.exists(csv_files)]) {
    dat <- read_csv_safe(path)
    if (nrow(dat) && "check_type" %in% names(dat)) {
      values <- c(values, as.character(dat$check_type))
    }
  }
  rds_files <- file.path(model_dir, c(
    "check-unit-status.rds", "check-summary.rds", "check_manifest.rds"
  ))
  for (path in rds_files[file.exists(rds_files)]) {
    dat <- tryCatch(readRDS(path), error = function(e) NULL)
    one <- tryCatch(dat$check_type, error = function(e) NULL)
    if (!is.null(one)) values <- c(values, as.character(one))
  }
  values <- values[!is.na(values) & nzchar(trimws(values))]
  unique(normalize_check_type(values))
}

copy_check_status_files <- function(model_dir, diagnostic_dir) {
  files <- check_status_files(model_dir)
  if (!length(files)) return(character())
  dir.create(diagnostic_dir, recursive = TRUE, showWarnings = FALSE)
  copied <- vapply(files, function(path) {
    target <- file.path(diagnostic_dir, basename(path))
    if (!isTRUE(file.copy(path, target, overwrite = TRUE, copy.date = TRUE))) {
      stop("Could not preserve check status ledger from ", path, call. = FALSE)
    }
    normalize_loose(target)
  }, character(1L))
  unname(copied)
}

read_attached_index <- function(model_dir) {
  rds <- file.path(model_dir, "attached-checks-index.rds")
  csv <- file.path(model_dir, "attached-checks-index.csv")
  out <- if (file.exists(rds)) {
    tryCatch(readRDS(rds), error = function(e) NULL)
  } else {
    NULL
  }
  if (is.null(out) && file.exists(csv)) {
    out <- read_csv_safe(csv)
  }
  out <- as.data.frame(out %||% data.frame(), stringsAsFactors = FALSE)
  if (!nrow(out)) data.frame() else out
}

expand_attached_index <- function(dat, state = "preserved") {
  dat <- as.data.frame(dat %||% data.frame(), stringsAsFactors = FALSE)
  if (!nrow(dat)) return(data.frame())
  rows <- list()
  for (i in seq_len(nrow(dat))) {
    row <- dat[i, , drop = FALSE]
    values <- split_values(row$check_type %||% "")
    values <- unique(normalize_check_type(values))
    values <- values[nzchar(values)]
    if (!length(values)) next
    for (value in values) {
      one <- row
      one$check_type <- value
      one$attachment_state <- state
      one$updated_in_this_attach <- identical(state, "updated")
      rows[[length(rows) + 1L]] <- one
    }
  }
  bind_rows_fill(rows)
}

job_dir <- function(root, job) {
  job <- as.character(job %||% "")
  if (!nzchar(job)) return(character())
  exact <- file.path(root, job)
  if (dir.exists(exact)) return(normalize_loose(exact))
  if (!dir.exists(root)) return(character())
  dirs <- list.dirs(root, recursive = FALSE, full.names = TRUE)
  hits <- dirs[startsWith(basename(dirs), job)]
  if (length(hits)) return(normalize_loose(hits))

  global_provenance <- file.path(root, "kflow-provenance.json")
  if (file.exists(global_provenance) && requireNamespace("jsonlite", quietly = TRUE)) {
    prov <- tryCatch(jsonlite::read_json(global_provenance, simplifyVector = TRUE), error = function(e) NULL)
    inputs <- tryCatch(as.data.frame(prov$inputs, stringsAsFactors = FALSE), error = function(e) data.frame())
    if (nrow(inputs)) {
      fields <- intersect(c("job_number", "job_id", "id", "cluster_id", "job_label"), names(inputs))
      matched <- vapply(seq_len(nrow(inputs)), function(i) {
        values <- unique(as.character(unlist(inputs[i, fields, drop = FALSE], use.names = FALSE)))
        values <- values[!is.na(values) & nzchar(values)]
        any(values == job) || any(startsWith(values, job))
      }, logical(1))
      ids <- unique(as.character(inputs$job_id[matched]))
      ids <- ids[!is.na(ids) & nzchar(ids)]
      hits <- file.path(root, ids)
      hits <- hits[dir.exists(hits)]
      if (length(hits)) return(normalize_loose(hits))
    }
  }

  provenance_matches <- vapply(dirs, function(dir) {
    path <- file.path(dir, "kflow-provenance.json")
    if (!file.exists(path) || !requireNamespace("jsonlite", quietly = TRUE)) {
      return(FALSE)
    }
    prov <- tryCatch(jsonlite::read_json(path, simplifyVector = TRUE), error = function(e) NULL)
    values <- c(
      tryCatch(prov$job$job_number, error = function(e) ""),
      tryCatch(prov$job$job_id, error = function(e) ""),
      tryCatch(prov$job$id, error = function(e) ""),
      tryCatch(prov$job$cluster_id, error = function(e) "")
    )
    values <- unique(as.character(values[!is.na(values)]))
    any(values == job) || any(startsWith(values, job))
  }, logical(1))
  normalize_loose(dirs[provenance_matches])
}

input_child_dirs <- function(root) {
  if (!dir.exists(root)) return(character())
  dirs <- list.dirs(root, recursive = FALSE, full.names = TRUE)
  normalize_loose(dirs[dir.exists(dirs)])
}

candidate_rows_from_roots <- function(roots) {
  rows <- lapply(roots, function(root) {
    dat <- discover_model_outputs(root)
    if (!nrow(dat)) return(dat)
    dat$input_root <- normalize_loose(root)
    dat
  })
  bind_rows_fill(rows)
}

base_roots <- if (nzchar(base_input_job)) {
  job_dir(input_root, base_input_job)
} else {
  normalize_loose(input_root)
}
if (!length(base_roots)) {
  stop("Base model input job directory was not found: ", base_input_job, call. = FALSE)
}

base_candidates <- candidate_rows_from_roots(base_roots)
if (nrow(base_candidates)) {
  write.csv(base_candidates, file.path(output_dir, "base-model-candidates.csv"), row.names = FALSE)
}
base_selected <- select_model_output(base_candidates, model_selector)
base_dir <- as.character(base_selected$compact_dir %||% "")
if (!nzchar(base_dir) || !dir.exists(base_dir)) {
  stop("Selected base model directory was not found.", call. = FALSE)
}

model_key <- gsub("[^A-Za-z0-9_.-]+", "_", as.character(base_selected$model_key %||% model_selector %||% "model"))
if (!nzchar(model_key)) model_key <- "model"
target_dir <- file.path(output_dir, "models", model_key)
invisible(copy_dir(base_dir, target_dir))
diagnostic_names <- diagnostic_dir_names()

previous_attached <- read_attached_index(target_dir)
if (!nrow(previous_attached)) {
  preserved_dirs <- diagnostic_names[dir.exists(file.path(target_dir, diagnostic_names))]
  if (length(preserved_dirs)) {
    previous_attached <- data.frame(
      check_type = preserved_dirs,
      source_input_root = normalize_loose(base_roots[[1L]] %||% ""),
      source_check_dir = normalize_loose(base_dir),
      attached_model_dir = normalize_loose(target_dir),
      attached_at = as.character(base_selected$attached_at %||% ""),
      stringsAsFactors = FALSE
    )
  }
}

requested_types <- normalize_check_type(attach_check_types)
requested_types <- requested_types[nzchar(requested_types)]

check_roots <- if (length(check_input_jobs)) {
  unique(unlist(lapply(check_input_jobs, job_dir, root = input_root), use.names = FALSE))
} else {
  setdiff(input_child_dirs(input_root), base_roots)
}
check_roots <- normalize_loose(check_roots[dir.exists(check_roots)])
if (!length(check_roots)) {
  stop("No check input job directories found.", call. = FALSE)
}

check_candidates <- candidate_rows_from_roots(check_roots)
if (nrow(check_candidates)) {
  write.csv(check_candidates, file.path(output_dir, "check-model-candidates.csv"), row.names = FALSE)
}

if (!nrow(check_candidates)) {
  stop("No model-like check outputs found in input jobs.", call. = FALSE)
}

matches <- vapply(seq_len(nrow(check_candidates)), function(i) {
  matches_selector(check_candidates[i, , drop = FALSE], model_selector)
}, logical(1))
check_candidates <- check_candidates[matches, , drop = FALSE]
if (!nrow(check_candidates)) {
  stop("No check outputs matched MODEL_SELECTOR=", shQuote(model_selector), call. = FALSE)
}

candidate_check_types <- function(row) {
  compact_dir <- as.character(row$compact_dir %||% "")
  values <- c(
    row$attached_check_type %||% "",
    row$check_type %||% "",
    row$merged_check_type %||% ""
  )
  manifest <- file.path(compact_dir, "check_manifest.csv")
  if (file.exists(manifest)) {
    dat <- read_csv_safe(manifest)
    if (nrow(dat)) values <- c(values, dat$check_type %||% "")
  }
  dirs <- diagnostic_names[dir.exists(file.path(compact_dir, diagnostic_names))]
  values <- c(values, dirs, status_check_types(compact_dir))
  values <- values[!is.na(values) & nzchar(trimws(as.character(values)))]
  unique(normalize_check_type(values))
}

has_requested_diagnostics <- function(row) {
  compact_dir <- as.character(row$compact_dir %||% "")
  dirs <- diagnostic_names[dir.exists(file.path(compact_dir, diagnostic_names))]
  ledger_types <- status_check_types(compact_dir)
  has_status_ledger <- has_check_status_ledger(compact_dir) && length(ledger_types) > 0L
  if (!length(requested_types)) return(length(dirs) > 0L || has_status_ledger)
  any(normalize_check_type(dirs) %in% requested_types) ||
    (has_status_ledger && any(ledger_types %in% requested_types))
}

check_candidates <- check_candidates[vapply(seq_len(nrow(check_candidates)), function(i) {
  has_requested_diagnostics(check_candidates[i, , drop = FALSE])
}, logical(1)), , drop = FALSE]
if (!nrow(check_candidates)) {
  stop("No requested diagnostic folders found in check outputs.", call. = FALSE)
}

check_candidates$.candidate_score <- vapply(seq_len(nrow(check_candidates)), function(i) {
  row <- check_candidates[i, , drop = FALSE]
  score <- candidate_score(row)
  compact_dir <- as.character(row$compact_dir %||% "")
  score <- score + 10L * sum(dir.exists(file.path(compact_dir, diagnostic_names)))
  if (truthy(row$attached_checks %||% "", FALSE)) score <- score + 50L
  score
}, numeric(1))
check_candidates <- check_candidates[order(check_candidates$input_root, -check_candidates$.candidate_score), , drop = FALSE]
check_candidates <- check_candidates[!duplicated(check_candidates$input_root), , drop = FALSE]

attached_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
attached_rows <- list()
for (i in seq_len(nrow(check_candidates))) {
  row <- check_candidates[i, , drop = FALSE]
  source_dir <- as.character(row$compact_dir %||% "")
  copied <- character()
  ledger_types <- status_check_types(source_dir)
  for (name in diagnostic_names) {
    source <- file.path(source_dir, name)
    if (!dir.exists(source)) next
    if (length(requested_types) && !normalize_check_type(name) %in% requested_types) next
    target <- file.path(target_dir, name)
    if (dir.exists(target)) unlink(target, recursive = TRUE, force = TRUE)
    copy_dir(source, target)
    if (normalize_check_type(name) %in% ledger_types) {
      copy_check_status_files(source_dir, target)
    }
    copied <- c(copied, name)
  }
  # A fan-in merge can contain only missing expected-unit rows and therefore
  # have no raw diagnostic directory at all.  Materialize the requested
  # diagnostic directory and retain the merge ledger instead of silently
  # dropping that failed evidence from the attached model bundle.
  ledger_types <- ledger_types[ledger_types %in% normalize_check_type(diagnostic_names)]
  if (length(requested_types)) ledger_types <- ledger_types[ledger_types %in% requested_types]
  ledger_only_types <- setdiff(ledger_types, copied)
  for (name in ledger_only_types) {
    target <- file.path(target_dir, name)
    # The base can be a previous attached bundle. A ledger-only current merge
    # must replace, rather than coexist with, stale successful diagnostic files
    # from that older bundle.
    if (dir.exists(target)) unlink(target, recursive = TRUE, force = TRUE)
    copy_check_status_files(source_dir, target)
    copied <- c(copied, name)
  }
  copied <- unique(copied)
  if (!length(copied)) next
  attached_rows[[length(attached_rows) + 1L]] <- data.frame(
    check_type = paste(copied, collapse = " "),
    source_input_root = normalize_loose(row$input_root %||% ""),
    source_check_dir = normalize_loose(source_dir),
    attached_model_dir = normalize_loose(target_dir),
    attached_at = attached_at,
    stringsAsFactors = FALSE
  )
}

updated_attached <- bind_rows_fill(attached_rows)
if (!nrow(updated_attached)) {
  stop("No diagnostic folders were attached.", call. = FALSE)
}
updated_attached <- expand_attached_index(updated_attached, state = "updated")
updated_types <- unique(normalize_check_type(updated_attached$check_type %||% ""))

preserved_attached <- expand_attached_index(previous_attached, state = "preserved")
if (nrow(preserved_attached) && length(updated_types)) {
  preserved_attached <- preserved_attached[
    !normalize_check_type(preserved_attached$check_type %||% "") %in% updated_types,
    ,
    drop = FALSE
  ]
}

attached <- bind_rows_fill(list(preserved_attached, updated_attached))
if (!nrow(attached)) {
  stop("No diagnostic folders were attached.", call. = FALSE)
}
attached$attached_model_dir <- normalize_loose(target_dir)
attached$output_mode <- attach_output_mode
attached$overlay_base_required <- identical(attach_output_mode, "delta")
attached$overlay_payload_mode <- if (identical(attach_output_mode, "delta")) "diagnostics_with_payload" else "standalone"

write.csv(attached, file.path(output_dir, "attached-checks-index.csv"), row.names = FALSE)
write.csv(attached, file.path(target_dir, "attached-checks-index.csv"), row.names = FALSE)
saveRDS(attached, file.path(target_dir, "attached-checks-index.rds"), compress = "xz")
refresh_ok <- refresh_diagnostic_model_bundle(target_dir)
if (!isTRUE(refresh_ok) && payload_refresh_required(TRUE)) {
  stop("Attached diagnostic payload refresh failed for ", target_dir,
       "; see diagnostic-refresh-status.csv", call. = FALSE)
}

index <- as.data.frame(base_selected, stringsAsFactors = FALSE)
index <- index[seq_len(1L), , drop = FALSE]
if (".candidate_score" %in% names(index)) index$.candidate_score <- NULL
index$model_dir <- file.path("models", model_key)
index$model_folder <- model_key
index$attached_checks <- TRUE
retained_types <- unique(normalize_check_type(attached$check_type %||% ""))
retained_types <- retained_types[nzchar(retained_types)]
index$attached_check_type <- paste(retained_types, collapse = " ")
index$attached_at <- attached_at
index$attached_model_dir <- normalize_loose(target_dir)
index$payload_role <- "model_root"
index$attach_output_mode <- attach_output_mode
index$overlay_base_required <- identical(attach_output_mode, "delta")
index$overlay_base_input_job <- original_base_input_job
index$overlay_payload_mode <- if (identical(attach_output_mode, "delta")) "diagnostics_with_payload" else "standalone"
write.csv(index, file.path(output_dir, "model-index.csv"), row.names = FALSE)

manifest <- data.frame(
  schema = "ofp-sam.checks.attached-model-bundle.v1",
  created_at = attached_at,
  model_key = model_key,
  model_selector = model_selector,
  base_model_dir = normalize_loose(base_dir),
  attached_model_dir = normalize_loose(target_dir),
  check_types = index$attached_check_type[[1L]],
  updated_check_types = paste(updated_types, collapse = " "),
  retained_check_types = paste(retained_types, collapse = " "),
  n_check_sources = nrow(attached),
  output_mode = attach_output_mode,
  overlay_base_required = identical(attach_output_mode, "delta"),
  overlay_base_input_job = original_base_input_job,
  overlay_payload_mode = if (identical(attach_output_mode, "delta")) "diagnostics_with_payload" else "standalone",
  overlay_replace_payload = identical(attach_output_mode, "delta"),
  inventory_excluded_files = paste(
    attached_output_inventory_exclusions(),
    collapse = " "
  ),
  stringsAsFactors = FALSE
)
write.csv(manifest, file.path(output_dir, "attached-model-bundle.csv"), row.names = FALSE)
saveRDS(as.list(manifest), file.path(output_dir, "attached-model-bundle.rds"), compress = "xz")

finalized <- finalize_attached_output(
  output_dir = output_dir,
  model_dir = target_dir,
  model_key = model_key,
  updated_check_types = updated_types,
  retained_check_types = retained_types,
  output_mode = attach_output_mode
)
manifest$n_removed_entries <- finalized$n_removed_entries
manifest$removed_bytes <- finalized$removed_bytes
manifest$n_published_files <- finalized$n_published_files
manifest$published_bytes <- finalized$published_bytes
write.csv(manifest, file.path(output_dir, "attached-model-bundle.csv"), row.names = FALSE)
saveRDS(as.list(manifest), file.path(output_dir, "attached-model-bundle.rds"), compress = "xz")

message("[checks] attached check outputs under ", target_dir)
