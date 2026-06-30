source("R/model_output_adapter.R")

message("[checks] attaching check outputs to model bundle")

input_root <- env("MODEL_INPUT_ROOT", default_input_root())
output_dir <- env("OUTPUT_DIR", "outputs")
model_selector <- env("MODEL_SELECTOR", "")
attach_check_types <- split_values(env("ATTACH_CHECK_TYPES", env("CHECK_TYPES", "")))
attach_check_types <- gsub("_", "-", tolower(attach_check_types))
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

copy_file_if_exists <- function(from, to_dir, to_name = basename(from)) {
  if (!file.exists(from)) return(FALSE)
  dir.create(to_dir, recursive = TRUE, showWarnings = FALSE)
  isTRUE(file.copy(from, file.path(to_dir, to_name), overwrite = TRUE, copy.date = TRUE))
}

merge_dir_contents <- function(from, to) {
  if (!dir.exists(from)) stop("Directory not found: ", from, call. = FALSE)
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  entries <- list.files(from, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  copied <- character()
  for (entry in entries) {
    target <- file.path(to, basename(entry))
    if (dir.exists(entry)) {
      copied <- c(copied, merge_dir_contents(entry, target))
    } else {
      if (file.exists(target)) {
        stop("Refusing to overwrite existing attached check file: ", target, call. = FALSE)
      }
      ok <- file.copy(entry, target, overwrite = FALSE, copy.date = TRUE)
      if (!isTRUE(ok)) stop("Could not copy ", entry, " to ", target, call. = FALSE)
      copied <- c(copied, normalize_loose(target))
    }
  }
  copied
}

relative_to <- function(path, root = output_dir) {
  path <- normalize_loose(path)
  root <- normalize_loose(root)
  prefix <- paste0(root, "/")
  if (identical(path, root)) return(".")
  if (startsWith(path, prefix)) substring(path, nchar(prefix) + 1L) else path
}

path_parts <- function(path) {
  strsplit(normalize_loose(path), "/", fixed = TRUE)[[1L]]
}

is_check_candidate <- function(row) {
  check_value <- as.character(row$check_type %||% "")
  index_file <- normalize_loose(as.character(row$index_file %||% ""))
  compact_dir <- normalize_loose(as.character(row$compact_dir %||% ""))
  nzchar(check_value) ||
    grepl("/checks/", index_file, fixed = TRUE) ||
    grepl("/checks/", compact_dir, fixed = TRUE)
}

select_base_model <- function(root) {
  candidates <- discover_model_outputs(root)
  if (nrow(candidates)) {
    write.csv(candidates, file.path(output_dir, "attach-model-candidates.csv"), row.names = FALSE)
  }
  if (!nrow(candidates)) {
    stop("No model outputs found under ", root, call. = FALSE)
  }
  base <- candidates[!vapply(seq_len(nrow(candidates)), function(i) is_check_candidate(candidates[i, , drop = FALSE]), logical(1)), , drop = FALSE]
  if (!nrow(base)) {
    stop("No base model output found. Attach the original model-run job as an input job.", call. = FALSE)
  }
  select_model_output(base, model_selector)
}

safe_model_key <- function(row) {
  value <- as.character(row$step_id %||% row$model_key %||% basename(row$compact_dir %||% "model"))
  value <- gsub("[^A-Za-z0-9_.-]+", "_", value)
  if (nzchar(value)) value else "model"
}

infer_check_type <- function(check_dir) {
  csv_file <- file.path(check_dir, "check_manifest.csv")
  if (file.exists(csv_file)) {
    dat <- read_csv_safe(csv_file)
    value <- as.character(dat$check_type %||% "")
    value <- value[nzchar(value)]
    if (length(value)) return(gsub("_", "-", tolower(value[[1L]])))
  }
  rds_file <- file.path(check_dir, "check_manifest.rds")
  if (file.exists(rds_file)) {
    dat <- tryCatch(readRDS(rds_file), error = function(e) NULL)
    value <- as.character(tryCatch(dat$check_type, error = function(e) ""))
    value <- value[nzchar(value)]
    if (length(value)) return(gsub("_", "-", tolower(value[[1L]])))
  }
  parts <- path_parts(check_dir)
  hits <- which(parts == "checks")
  if (length(hits) && hits[[length(hits)]] < length(parts)) {
    return(gsub("_", "-", tolower(parts[[hits[[length(hits)]] + 1L]])))
  }
  ""
}

check_dir_matches_model <- function(check_dir, selector, base_key) {
  if (!nzchar(selector) && !nzchar(base_key)) return(TRUE)
  values <- c(basename(check_dir), base_key)
  index_file <- file.path(dirname(check_dir), "model-index.csv")
  if (file.exists(index_file)) {
    idx <- read_csv_safe(index_file)
    if (nrow(idx)) {
      row <- idx[basename(as.character(idx$model_dir %||% "")) == basename(check_dir), , drop = FALSE]
      if (!nrow(row)) row <- idx[seq_len(1L), , drop = FALSE]
      values <- c(values, unlist(row, use.names = FALSE))
    }
  }
  values <- unique(as.character(values[!is.na(values)]))
  values <- unique(c(values, basename(values[nzchar(values)])))
  if (nzchar(selector) && (selector %in% values || any(grepl(selector, values, ignore.case = TRUE)))) return(TRUE)
  if (nzchar(base_key) && (base_key %in% values || any(grepl(base_key, values, ignore.case = TRUE)))) return(TRUE)
  FALSE
}

discover_check_dirs <- function(root, selector, base_key) {
  roots <- normalize_loose(root)
  roots <- roots[dir.exists(roots)]
  dirs <- unique(unlist(lapply(roots, function(one_root) {
    dirname(list.files(
      one_root,
      pattern = "^check_manifest[.](rds|csv)$",
      recursive = TRUE,
      full.names = TRUE
    ))
  }), use.names = FALSE))
  dirs <- unique(normalize_loose(dirs))
  dirs <- dirs[dir.exists(dirs)]
  if (!length(dirs)) return(character())
  dirs <- dirs[vapply(dirs, check_dir_matches_model, logical(1), selector = selector, base_key = base_key)]
  if (length(attach_check_types)) {
    dirs <- dirs[vapply(dirs, function(x) infer_check_type(x) %in% attach_check_types, logical(1))]
  }
  unique(dirs)
}

copy_base_index <- function(base_row, model_key, target_dir) {
  index_file <- as.character(base_row$index_file %||% "")
  index <- if (nzchar(index_file) && file.exists(index_file)) read_csv_safe(index_file) else data.frame()
  if (!nrow(index)) {
    index <- as.data.frame(base_row, stringsAsFactors = FALSE)
  }
  if (nrow(index) > 1L) {
    index <- index[vapply(seq_len(nrow(index)), function(i) matches_selector(index[i, , drop = FALSE], model_selector), logical(1)), , drop = FALSE]
    if (!nrow(index)) index <- as.data.frame(base_row, stringsAsFactors = FALSE)
  }
  index <- index[seq_len(1L), , drop = FALSE]
  index$model_dir <- file.path("models", model_key)
  index$model_folder <- model_key
  index$attached_checks <- TRUE
  index$attached_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  index$attached_model_dir <- normalize_loose(target_dir)
  write.csv(index, file.path(output_dir, "model-index.csv"), row.names = FALSE)
  index
}

attach_check_dir <- function(check_dir, target_dir) {
  check_type <- infer_check_type(check_dir)
  if (!nzchar(check_type)) stop("Could not infer check type for ", check_dir, call. = FALSE)
  diagnostic_dirs <- c("jitter", "retro", "profile", "hessian", "selftest", "aspm", "projection")
  present <- diagnostic_dirs[dir.exists(file.path(check_dir, diagnostic_dirs))]
  if (!length(present)) {
    stop("No diagnostic subdirectories found in ", check_dir, call. = FALSE)
  }
  copied <- character()
  for (name in present) {
    copied <- c(copied, merge_dir_contents(file.path(check_dir, name), file.path(target_dir, name)))
  }
  data.frame(
    check_type = check_type,
    source_check_dir = normalize_loose(check_dir),
    target_model_dir = normalize_loose(target_dir),
    copied_dirs = paste(present, collapse = " "),
    copied_files = length(copied),
    stringsAsFactors = FALSE
  )
}

base_row <- select_base_model(input_root)
model_key <- safe_model_key(base_row)
base_dir <- normalize_loose(as.character(base_row$compact_dir %||% ""))
if (!dir.exists(base_dir)) stop("Base model compact directory not found: ", base_dir, call. = FALSE)

target_dir <- file.path(output_dir, "models", model_key)
copy_dir(base_dir, target_dir)

base_root <- normalize_loose(dirname(dirname(base_dir)))
if (dir.exists(file.path(base_root, "region-map"))) {
  copy_dir(file.path(base_root, "region-map"), file.path(output_dir, "region-map"))
}

check_dirs <- discover_check_dirs(input_root, model_selector, model_key)
if (!length(check_dirs)) {
  stop("No check outputs found to attach for model ", model_key, ". Attach completed check jobs as input jobs.", call. = FALSE)
}

attached <- bind_rows_fill(lapply(check_dirs, attach_check_dir, target_dir = target_dir))
write.csv(attached, file.path(output_dir, "attached-checks-index.csv"), row.names = FALSE)
write.csv(attached, file.path(target_dir, "attached-checks-index.csv"), row.names = FALSE)
saveRDS(attached, file.path(target_dir, "attached-checks-index.rds"), compress = "xz")

index <- copy_base_index(base_row, model_key, target_dir)

if (requireNamespace("mfclkit", quietly = TRUE)) {
  try(mfclkit::mfk_collect_diagnostics(target_dir, write_index = TRUE), silent = FALSE)
}
if (requireNamespace("mfclshiny", quietly = TRUE)) {
  payload_index <- tryCatch(
    mfclshiny::build_model_payloads(target_dir, recursive = TRUE, overwrite = TRUE),
    error = function(e) {
      warning("mfclshiny payload build failed: ", conditionMessage(e), call. = FALSE)
      data.frame()
    }
  )
  if (is.data.frame(payload_index)) {
    write.csv(payload_index, file.path(target_dir, "payload-build-index.csv"), row.names = FALSE)
  }
}
if (requireNamespace("mfclkit", quietly = TRUE)) {
  try(mfclkit::mfk_collect_diagnostics(target_dir, write_index = TRUE), silent = FALSE)
}

manifest <- data.frame(
  schema = "ofp-sam.checks.attached-model-bundle.v1",
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  model_key = model_key,
  model_selector = model_selector,
  base_model_dir = base_dir,
  attached_model_dir = normalize_loose(target_dir),
  n_attached_check_dirs = nrow(attached),
  attached_check_types = paste(sort(unique(attached$check_type)), collapse = " "),
  stringsAsFactors = FALSE
)
write.csv(manifest, file.path(output_dir, "attached-model-bundle.csv"), row.names = FALSE)
saveRDS(as.list(manifest), file.path(output_dir, "attached-model-bundle.rds"), compress = "xz")

message("[checks] attached ", nrow(attached), " check output(s) to ", target_dir)
