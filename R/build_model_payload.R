source("R/model_output_adapter.R")

suppressPackageStartupMessages(library(mfclshiny))

message("[checks] building MFCL Shiny payload from fitted-model output")

input_root <- env("MODEL_INPUT_ROOT", default_input_root())
output_dir <- env("OUTPUT_DIR", "outputs")
work_dir <- env("WORK_DIR", "work")
model_selector <- env("MODEL_SELECTOR", "")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)

candidates <- discover_model_outputs(input_root)
if (!nrow(candidates)) {
  stop("No fitted model outputs were found under ", input_root, ".", call. = FALSE)
}
write.csv(
  candidates,
  file.path(output_dir, "model-candidates.csv"),
  row.names = FALSE
)

selected <- select_model_output(candidates, model_selector)
source_dir <- as.character(selected$compact_dir %||% "")
if (!nzchar(source_dir) || !dir.exists(source_dir)) {
  stop("The selected fitted model directory was not found.", call. = FALSE)
}
source_files <- list.files(
  source_dir,
  recursive = TRUE,
  full.names = TRUE,
  all.files = TRUE,
  no.. = TRUE
)
source_files <- source_files[file.info(source_files)$isdir %in% FALSE]
source_bytes <- sum(as.numeric(file.info(source_files)$size), na.rm = TRUE)

model_key <- gsub(
  "[^A-Za-z0-9_.-]+",
  "_",
  as.character(selected$model_key %||% model_selector %||% "model")
)
if (!nzchar(model_key)) model_key <- "model"

target_dir <- file.path(output_dir, "models", model_key)
if (dir.exists(target_dir)) unlink(target_dir, recursive = TRUE, force = TRUE)
copy_dir(source_dir, target_dir)

payload_file <- file.path(target_dir, "model_payload.rds")
payload <- mfclshiny::build_model_payload(
  folder = target_dir,
  output_file = payload_file,
  overwrite = TRUE,
  recursive = FALSE,
  object_cache = "all",
  # Preserve the complete set of model-facing raw artifacts inside the RDS so
  # the compact archive is both directly viewable and independently restorable.
  artifacts = "all",
  parallel = FALSE
)

if (!file.exists(payload_file) || file.info(payload_file)$size <= 0) {
  stop("MFCL Shiny did not create a non-empty model_payload.rds.", call. = FALSE)
}
validated <- tryCatch(readRDS(payload_file), error = function(e) e)
if (inherits(validated, "error") || is.null(validated)) {
  detail <- if (inherits(validated, "error")) conditionMessage(validated) else "payload is NULL"
  stop("The generated model_payload.rds failed validation: ", detail, call. = FALSE)
}

manifest_csv <- file.path(target_dir, "model_payload_manifest.csv")
manifest_json <- file.path(target_dir, "model_payload_manifest.json")
if ("write_model_payload_manifest" %in% getNamespaceExports("mfclshiny")) {
  mfclshiny::write_model_payload_manifest(
    payload = validated,
    folder = target_dir,
    payload_file = payload_file
  )
}

restore_dir <- file.path(work_dir, "payload-restore", model_key)
if (dir.exists(restore_dir)) unlink(restore_dir, recursive = TRUE, force = TRUE)
dir.create(restore_dir, recursive = TRUE, showWarnings = FALSE)
restored <- mfclshiny::restore_model_payload_files(
  payload_file,
  output_dir = restore_dir,
  overwrite = TRUE
)
if (!is.data.frame(restored) || !nrow(restored)) {
  stop("The generated payload did not restore any model files.", call. = FALSE)
}

source_role_file <- function(role) {
  candidates <- switch(
    role,
    par = file.path(target_dir, "final.par"),
    length_fit = file.path(target_dir, "length.fit"),
    weight_fit = file.path(target_dir, "weight.fit"),
    temporary_tag_report = file.path(target_dir, "temporary_tag_report"),
    age_length_fit = file.path(target_dir, "agelengthresids.dat"),
    indepvar = file.path(target_dir, "indepvar.rpt"),
    tag = list.files(target_dir, pattern = "[.]tag$", full.names = TRUE),
    age_length = list.files(target_dir, pattern = "[.]age_length$", full.names = TRUE),
    character()
  )
  candidates <- candidates[file.exists(candidates)]
  if (length(candidates)) candidates[[1L]] else ""
}

required_roles <- c("par", "rep")
optional_raw_roles <- c(
  "temporary_tag_report", "length_fit", "weight_fit", "tag",
  "age_length", "indepvar"
)
required_roles <- unique(c(
  required_roles,
  optional_raw_roles[vapply(optional_raw_roles, function(role) {
    nzchar(source_role_file(role))
  }, logical(1L))]
))
restored$source_file <- vapply(restored$role, source_role_file, character(1L))
restored$required <- restored$role %in% required_roles
restored$restored_md5 <- unname(tools::md5sum(restored$file))
restored$source_md5 <- vapply(restored$source_file, function(path) {
  if (nzchar(path) && file.exists(path)) unname(tools::md5sum(path)) else ""
}, character(1L))
restored$source_matches <- !nzchar(restored$source_md5) |
  restored$restored_md5 == restored$source_md5
missing_roles <- setdiff(required_roles, restored$role)
mismatched_roles <- restored$role[restored$required & !restored$source_matches]
if (length(missing_roles) || length(mismatched_roles)) {
  stop(
    "Payload restoration validation failed; missing roles: ",
    paste(missing_roles, collapse = ", "),
    "; checksum mismatches: ",
    paste(mismatched_roles, collapse = ", "),
    call. = FALSE
  )
}
write.csv(restored, file.path(target_dir, "payload-restore-audit.csv"), row.names = FALSE)
saveRDS(restored, file.path(target_dir, "payload-restore-audit.rds"), compress = "xz")
if (requireNamespace("jsonlite", quietly = TRUE)) {
  jsonlite::write_json(
    restored,
    file.path(target_dir, "payload-restore-audit.json"),
    dataframe = "rows",
    auto_unbox = TRUE,
    pretty = TRUE,
    null = "null"
  )
}
writeLines(
  c(
    "Portable MFCL model payload",
    "",
    "Open directly with MFCL Shiny by selecting this folder.",
    "Restore embedded model files with:",
    "Rscript -e 'mfclshiny::restore_model_payload_files(\"model_payload.rds\", output_dir=\"restored\", overwrite=TRUE)'"
  ),
  file.path(target_dir, "README.txt")
)

keep_names <- c(
  "model_payload.rds",
  "model_payload_manifest.csv",
  "model_payload_manifest.json",
  "payload-restore-audit.csv",
  "payload-restore-audit.json",
  "payload-restore-audit.rds",
  "README.txt",
  "final.par.sha256",
  "model_info.rds",
  "mfclkit_diagnostics.rds",
  "tag-tau-audit.csv",
  "fishery_map.R",
  "tag_rep_map.R",
  "region_map.geojson",
  "region-map.geojson",
  "regions.geojson",
  "region_map.json",
  "region-map.json",
  "regions.json",
  "region_map.csv",
  "region-map.csv",
  "regions.csv"
)
target_entries <- list.files(
  target_dir,
  full.names = TRUE,
  all.files = TRUE,
  no.. = TRUE
)
remove_entries <- target_entries[!(basename(target_entries) %in% keep_names)]
if (length(remove_entries)) unlink(remove_entries, recursive = TRUE, force = TRUE)
if (!file.exists(payload_file) || is.null(tryCatch(readRDS(payload_file), error = function(e) NULL))) {
  stop("Compact cleanup damaged model_payload.rds.", call. = FALSE)
}
compact_files <- list.files(
  target_dir,
  recursive = TRUE,
  full.names = TRUE,
  all.files = TRUE,
  no.. = TRUE
)
compact_files <- compact_files[file.info(compact_files)$isdir %in% FALSE]
compact_bytes <- sum(as.numeric(file.info(compact_files)$size), na.rm = TRUE)

index <- as.data.frame(selected, stringsAsFactors = FALSE)
index <- index[seq_len(1L), , drop = FALSE]
if (".candidate_score" %in% names(index)) index$.candidate_score <- NULL
index$model_key <- model_key
index$model_dir <- file.path("models", model_key)
index$model_folder <- model_key
index$payload_file <- file.path(index$model_dir, "model_payload.rds")
index$payload_role <- "model_root"
index$payload_built <- TRUE
index$payload_bytes <- as.numeric(file.info(payload_file)$size)
index$payload_validated <- TRUE
index$payload_built_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
write.csv(index, file.path(output_dir, "model-index.csv"), row.names = FALSE)

audit <- data.frame(
  schema = "ofp-sam.checks.payload-build.v1",
  model_key = model_key,
  source_dir = normalize_loose(source_dir),
  target_dir = normalize_loose(target_dir),
  payload_file = normalize_loose(payload_file),
  payload_bytes = as.numeric(file.info(payload_file)$size),
  payload_readable = TRUE,
  artifact_mode = as.character(validated$artifact_mode %||% ""),
  object_cache_mode = as.character(validated$object_cache_mode %||% ""),
  manifest_csv = file.exists(manifest_csv),
  manifest_json = file.exists(manifest_json),
  restore_validated = TRUE,
  restored_roles = paste(restored$role, collapse = ";"),
  required_roles = paste(required_roles, collapse = ";"),
  source_file_count = length(source_files),
  source_bytes = source_bytes,
  compact_file_count = length(compact_files),
  compact_bytes = compact_bytes,
  built_at = index$payload_built_at[[1L]],
  stringsAsFactors = FALSE
)
write.csv(audit, file.path(output_dir, "payload-build-audit.csv"), row.names = FALSE)
saveRDS(as.list(audit), file.path(output_dir, "payload-build-audit.rds"), compress = "xz")

message(
  "[checks] validated MFCL Shiny payload: ",
  normalize_loose(payload_file),
  " (", format(file.info(payload_file)$size, big.mark = ","), " bytes)"
)
