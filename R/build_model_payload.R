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
  artifacts = "core",
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
  manifest_csv = file.exists(manifest_csv),
  manifest_json = file.exists(manifest_json),
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
