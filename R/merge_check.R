source("R/model_output_adapter.R")

raw_check_type <- tolower(env("CHECK_MERGE_TYPE", env("CHECK_TYPE", "")))
check_type <- gsub("[-_]merge$", "", raw_check_type)
check_type <- gsub("_", "-", check_type)
if (!check_type %in% c("aspm", "jitter", "profile", "retro", "selftest")) {
  stop("Unsupported merge CHECK_TYPE: ", raw_check_type, call. = FALSE)
}
attach_check_types <- normalize_attached_check_types(env("ATTACH_CHECK_TYPES", ""))
if (length(attach_check_types) && !identical(attach_check_types, check_type)) {
  stop(
    "ATTACH_CHECK_TYPES must contain only the current merge type ",
    shQuote(check_type), "; got ", paste(attach_check_types, collapse = ", "), ".",
    call. = FALSE
  )
}

require_mfclkit <- function(required_for = check_type) {
  if (requireNamespace("mfclkit", quietly = TRUE)) return(invisible(TRUE))
  stop("mfclkit is required to merge ", required_for, " outputs.", call. = FALSE)
}

if (check_type %in% c("jitter", "profile", "retro") &&
    truthy(env("CHECK_REQUIRE_MFCLKIT", env("CHECK_ENRICH_PAYLOADS", "true")), TRUE)) {
  require_mfclkit(check_type)
}

message("[checks] merging split ", check_type, " jobs")

input_root <- env("MODEL_INPUT_ROOT", default_input_root())
output_dir <- env("OUTPUT_DIR", "outputs")
model_selector <- env("MODEL_SELECTOR", "")
smoke_only <- truthy(env("CHECK_SMOKE_ONLY", env("CHECK_DRY_RUN", "false")), FALSE)
attach_output_mode <- normalize_attached_output_mode()
base_input_job <- env("MODEL_BASE_INPUT_JOB", env("BASE_MODEL_JOB", ""))
original_base_input_job <- env("MODEL_ORIGINAL_BASE_INPUT_JOB", base_input_job)
check_input_jobs <- split_values(env("CHECK_INPUT_JOBS", ""))
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

canonical_check_unit_values <- function(values, unit_type) {
  original_na <- is.na(values)
  out <- trimws(as.character(values))
  out[original_na | !nzchar(out)] <- NA_character_
  if (unit_type %in% c("seed", "peel", "replicate")) {
    integer_like <- !is.na(out) & grepl("^[+]?[0-9]+$", out)
    parsed <- suppressWarnings(as.numeric(out))
    valid <- integer_like & is.finite(parsed) & parsed >= 1 &
      parsed <= .Machine$integer.max & parsed == floor(parsed)
    out[!is.na(out) & !valid] <- NA_character_
    out[valid] <- as.character(as.integer(parsed[valid]))
  } else if (identical(unit_type, "aspm")) {
    out <- tolower(out)
  }
  out
}

expected_unit_type <- tolower(trimws(env("CHECK_EXPECTED_UNIT_TYPE", "")))
expected_units_raw <- split_values(env("CHECK_EXPECTED_UNITS", ""))
if (xor(nzchar(expected_unit_type), length(expected_units_raw) > 0L)) {
  stop(
    "CHECK_EXPECTED_UNIT_TYPE and CHECK_EXPECTED_UNITS must be supplied together.",
    call. = FALSE
  )
}
expected_unit_check <- switch(
  expected_unit_type,
  seed = "jitter",
  peel = "retro",
  replicate = "selftest",
  aspm = "aspm",
  ""
)
if (nzchar(expected_unit_type) && !nzchar(expected_unit_check)) {
  stop("Unsupported CHECK_EXPECTED_UNIT_TYPE: ", expected_unit_type, call. = FALSE)
}
if (nzchar(expected_unit_check) && !identical(expected_unit_check, check_type)) {
  stop(
    "CHECK_EXPECTED_UNIT_TYPE=", expected_unit_type,
    " does not match CHECK_MERGE_TYPE=", check_type, ".",
    call. = FALSE
  )
}
expected_units <- if (expected_unit_type %in% c("seed", "peel", "replicate")) {
  as.character(positive_integer_values(
    paste(expected_units_raw, collapse = " "),
    default = integer(),
    option = "CHECK_EXPECTED_UNITS"
  ))
} else {
  unique(canonical_check_unit_values(expected_units_raw, expected_unit_type))
}
expected_units <- expected_units[!is.na(expected_units)]
expected_unit_ledger <- list(
  present = nzchar(expected_unit_type) && length(expected_units) > 0L,
  type = expected_unit_type,
  units = expected_units
)

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

profile_duplicate_records <- list()

profile_point_score <- function(dir) {
  info <- tryCatch(readRDS(file.path(dir, "profile_point_info.rds")),
                   error = function(e) NULL)
  payload <- tryCatch(readRDS(file.path(dir, "profile_payload.rds")),
                      error = function(e) NULL)
  value <- function(name, default = NA) {
    out <- tryCatch(info[[name]], error = function(e) NULL)
    if (is.null(out) || !length(out) || (length(out) == 1L && is.na(out))) {
      out <- tryCatch(payload[[name]], error = function(e) NULL)
    }
    if (is.null(out) || !length(out)) default else out[[1L]]
  }
  nll <- suppressWarnings(as.numeric(value("profile_nll", value("total_nll", NA_real_))))
  c(
    valid = as.integer(isTRUE(as.logical(value("point_valid", FALSE)))),
    completed = as.integer(isTRUE(as.logical(value("run_completed", FALSE)))),
    converged = as.integer(isTRUE(as.logical(value("converged", FALSE)))),
    nll_rank = if (is.finite(nll)) -nll else -Inf
  )
}

copy_profile_point_checked <- function(from, to) {
  if (!dir.exists(to)) return(copy_dir_contents_checked(from, to))
  incoming <- profile_point_score(from)
  existing <- profile_point_score(to)
  replace <- FALSE
  for (index in seq_along(incoming)) {
    if (incoming[[index]] == existing[[index]]) next
    replace <- incoming[[index]] > existing[[index]]
    break
  }
  action <- if (replace) "replaced_with_better_point" else "kept_existing_point"
  profile_duplicate_records[[length(profile_duplicate_records) + 1L]] <<- data.frame(
    source_dir = normalize_loose(from),
    target_dir = normalize_loose(to),
    action = action,
    incoming_valid = incoming[["valid"]],
    existing_valid = existing[["valid"]],
    incoming_nll_rank = incoming[["nll_rank"]],
    existing_nll_rank = existing[["nll_rank"]],
    stringsAsFactors = FALSE
  )
  if (!replace) return(normalize_loose(to))
  unlink(to, recursive = TRUE, force = TRUE)
  copy_dir_contents_checked(from, to)
}

# Gate duplicate NLL tie-breaking on objective/configuration comparability.
copy_profile_point_checked_unfiltered <- copy_profile_point_checked

merge_profile_missing <- function(x) {
  is.null(x) || !length(x) || all(is.na(x)) ||
    (is.character(x) && !any(nzchar(trimws(x))))
}

merge_profile_value <- function(info, payload, fields, default = NA) {
  containers <- list(
    info,
    payload,
    tryCatch(info$objective_provenance, error = function(e) NULL),
    tryCatch(payload$objective_provenance, error = function(e) NULL)
  )
  for (field in fields) {
    for (container in containers) {
      out <- tryCatch(container[[field]], error = function(e) NULL)
      if (!merge_profile_missing(out)) return(out[[1L]])
    }
  }
  default
}

merge_profile_text <- function(x) {
  if (merge_profile_missing(x)) return(NA_character_)
  out <- trimws(as.character(x[[1L]]))
  if (nzchar(out)) out else NA_character_
}

merge_profile_number <- function(x) {
  if (merge_profile_missing(x)) return(NA_real_)
  suppressWarnings(as.numeric(x[[1L]]))
}

merge_profile_logical <- function(x) {
  if (merge_profile_missing(x)) return(NA)
  if (is.logical(x)) return(x[[1L]])
  out <- tolower(trimws(as.character(x[[1L]])))
  if (out %in% c("true", "t", "1", "yes", "y")) return(TRUE)
  if (out %in% c("false", "f", "0", "no", "n")) return(FALSE)
  NA
}

merge_profile_equal <- function(x, y, tolerance = 1e-10) {
  if (merge_profile_missing(x) || merge_profile_missing(y)) return(NA)
  xn <- suppressWarnings(as.numeric(x[[1L]]))
  yn <- suppressWarnings(as.numeric(y[[1L]]))
  if (is.finite(xn) && is.finite(yn)) {
    return(abs(xn - yn) <= tolerance * max(1, abs(xn), abs(yn)))
  }
  identical(trimws(as.character(x[[1L]])), trimws(as.character(y[[1L]])))
}

merge_profile_point_metadata <- function(dir) {
  read_list <- function(path) {
    out <- tryCatch(readRDS(path), error = function(e) list())
    if (is.list(out)) out else list()
  }
  info <- read_list(file.path(dir, "profile_point_info.rds"))
  payload <- read_list(file.path(dir, "profile_payload.rds"))
  value <- function(fields, default = NA) {
    merge_profile_value(info, payload, fields, default)
  }
  scalar <- merge_profile_number(value(c("scalar", "profile_scalar")))
  if (!is.finite(scalar)) scalar <- suppressWarnings(as.numeric(basename(dir)))
  target_value <- value(c(
    "effective_target", "target_quantity", "quantity_target",
    "requested_target", "native_target", "target"
  ))
  target <- merge_profile_number(target_value)
  target_explicit <- is.finite(target)
  if (!target_explicit && is.finite(scalar)) target <- scalar
  source <- merge_profile_text(value("objective_source"))
  run_status <- merge_profile_text(value(c("run_status", "status")))
  completed <- merge_profile_logical(value(c("run_completed", "completed")))
  if (is.na(completed)) {
    completed <- !is.na(run_status) && run_status %in% c(
      "completed", "complete", "success", "base_anchor"
    )
  }
  list(
    dir = dir,
    scalar = scalar,
    target = target,
    target_explicit = target_explicit,
    valid = isTRUE(merge_profile_logical(value(c("point_valid", "valid")))),
    completed = isTRUE(completed),
    converged = isTRUE(merge_profile_logical(value("converged"))),
    nll = merge_profile_number(value(c("profile_nll", "total_nll", "objective"))),
    anchor = isTRUE(merge_profile_logical(value("base_anchor"))) ||
      identical(source, "fitted_model_par") || identical(run_status, "base_anchor"),
    objective_source = source,
    objective_evaluation = merge_profile_text(value("objective_evaluation")),
    objective_comparison_key = merge_profile_text(value("objective_comparison_key")),
    objective_comparable = merge_profile_logical(value("objective_comparable")),
    profile_cache_signature = merge_profile_text(value("profile_cache_signature")),
    configuration = list(
      profile = merge_profile_text(value(c("profile", "profile_name"))),
      quantity_type = merge_profile_text(value("quantity_type")),
      quantity_name = merge_profile_text(value(c("quantity_name", "quantity_label"))),
      af172 = merge_profile_text(value(c("Af172", "af172", "af_172"))),
      af173 = merge_profile_text(value(c("Af173", "af173", "af_173"))),
      af174 = merge_profile_text(value(c("Af174", "af174", "af_174")))
    )
  )
}

merge_profile_source_class <- function(source) {
  source <- tolower(if (merge_profile_missing(source)) "" else as.character(source[[1L]]))
  if (grepl("zero[_ -]?penalty.*harvest[_ -]?par", source)) {
    return("zero_penalty_harvest_par")
  }
  if (grepl("penali[sz]ed|fallback", source)) return("penalized_fallback")
  if (nzchar(source)) "other" else "missing"
}

merge_profile_candidate_comparability <- function(incoming, existing) {
  reasons <- character()
  legacy <- FALSE
  if (isTRUE(xor(isTRUE(incoming$anchor), isTRUE(existing$anchor)))) {
    reasons <- c(reasons, "fitted_anchor_vs_profile_candidate")
  }
  target_equal <- merge_profile_equal(incoming$target, existing$target)
  if (isFALSE(target_equal)) reasons <- c(reasons, "effective_target")
  if (is.na(target_equal) || !isTRUE(incoming$target_explicit) ||
      !isTRUE(existing$target_explicit)) legacy <- TRUE
  config_fields <- union(names(incoming$configuration), names(existing$configuration))
  for (field in config_fields) {
    equal <- merge_profile_equal(
      incoming$configuration[[field]], existing$configuration[[field]]
    )
    if (isFALSE(equal)) reasons <- c(reasons, paste0("configuration:", field))
    if (is.na(equal)) legacy <- TRUE
  }
  source_classes <- c(
    merge_profile_source_class(incoming$objective_source),
    merge_profile_source_class(existing$objective_source)
  )
  if (all(c("zero_penalty_harvest_par", "penalized_fallback") %in% source_classes)) {
    reasons <- c(reasons, "zero_penalty_harvest_par_vs_penalized_fallback")
  }
  for (field in c(
    "objective_comparison_key", "objective_evaluation", "objective_source"
  )) {
    equal <- merge_profile_equal(incoming[[field]], existing[[field]])
    if (isFALSE(equal)) reasons <- c(reasons, field)
    if (is.na(equal)) legacy <- TRUE
  }
  flags <- c(incoming$objective_comparable, existing$objective_comparable)
  if (any(flags %in% FALSE)) reasons <- c(reasons, "objective_not_comparable")
  if (any(is.na(flags))) legacy <- TRUE
  reasons <- unique(reasons)
  comparable <- !length(reasons)
  list(
    comparable = comparable,
    legacy = legacy,
    marker = if (!comparable) {
      paste(c("incomparable", reasons), collapse = ":")
    } else if (legacy) {
      "legacy_comparable_assumed"
    } else {
      "modern_comparable"
    },
    reasons = reasons
  )
}

merge_profile_execution_score <- function(metadata) {
  c(
    anchor = as.integer(isTRUE(metadata$anchor)),
    valid = as.integer(isTRUE(metadata$valid)),
    completed = as.integer(isTRUE(metadata$completed)),
    converged = as.integer(isTRUE(metadata$converged))
  )
}

merge_profile_better_execution <- function(incoming, existing) {
  for (index in seq_along(incoming)) {
    if (incoming[[index]] > existing[[index]]) return(TRUE)
    if (incoming[[index]] < existing[[index]]) return(FALSE)
  }
  FALSE
}

merge_profile_add_provenance <- function(index, comparison, incoming, existing, selected) {
  record <- profile_duplicate_records[[index]]
  values <- list(
    objective_comparable_for_selection = comparison$comparable,
    profile_comparability = comparison$marker,
    legacy_comparability = comparison$legacy,
    incoming_effective_target = incoming$target,
    existing_effective_target = existing$target,
    incoming_objective_comparison_key = incoming$objective_comparison_key,
    existing_objective_comparison_key = existing$objective_comparison_key,
    incoming_objective_evaluation = incoming$objective_evaluation,
    existing_objective_evaluation = existing$objective_evaluation,
    incoming_objective_source = incoming$objective_source,
    existing_objective_source = existing$objective_source,
    incoming_profile_cache_signature = incoming$profile_cache_signature,
    existing_profile_cache_signature = existing$profile_cache_signature,
    selected_objective_comparison_key = selected$objective_comparison_key,
    selected_objective_evaluation = selected$objective_evaluation,
    selected_objective_source = selected$objective_source,
    selected_profile_cache_signature = selected$profile_cache_signature
  )
  for (field in names(values)) record[[field]] <- values[[field]]
  profile_duplicate_records[[index]] <<- record
  invisible(NULL)
}

copy_profile_point_checked <- function(from, to) {
  if (!dir.exists(to)) return(copy_profile_point_checked_unfiltered(from, to))
  incoming <- merge_profile_point_metadata(from)
  existing <- merge_profile_point_metadata(to)
  comparison <- merge_profile_candidate_comparability(incoming, existing)
  before <- length(profile_duplicate_records)
  if (comparison$comparable) {
    copy_profile_point_checked_unfiltered(from, to)
  } else if (merge_profile_better_execution(
    merge_profile_execution_score(incoming), merge_profile_execution_score(existing)
  )) {
    copy_profile_point_checked_unfiltered(from, to)
  } else {
    profile_duplicate_records[[before + 1L]] <<- data.frame(
      source_dir = normalize_loose(from),
      target_dir = normalize_loose(to),
      action = "kept_existing_incomparable",
      incoming_valid = incoming$valid,
      existing_valid = existing$valid,
      incoming_nll_rank = if (is.finite(incoming$nll)) -incoming$nll else -Inf,
      existing_nll_rank = if (is.finite(existing$nll)) -existing$nll else -Inf,
      stringsAsFactors = FALSE
    )
  }
  index <- length(profile_duplicate_records)
  if (index == before) {
    profile_duplicate_records[[before + 1L]] <<- data.frame(
      source_dir = normalize_loose(from),
      target_dir = normalize_loose(to),
      action = "duplicate_selection_unrecorded",
      stringsAsFactors = FALSE
    )
    index <- before + 1L
  }
  merge_profile_add_provenance(
    index, comparison, incoming, existing, merge_profile_point_metadata(to)
  )
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

observed_check_unit_values <- function(dat, ledger = expected_unit_ledger) {
  if (!is.data.frame(dat) || !nrow(dat) || !isTRUE(ledger$present)) {
    return(character())
  }
  values <- switch(
    ledger$type,
    seed = if ("seed" %in% names(dat)) dat$seed else rep(NA_character_, nrow(dat)),
    peel = if ("peel" %in% names(dat)) dat$peel else rep(NA_character_, nrow(dat)),
    replicate = {
      field <- intersect(c("rep", "replicate", "selftest_rep"), names(dat))
      if (length(field)) dat[[field[[1L]]]] else rep(NA_character_, nrow(dat))
    },
    aspm = if ("folder" %in% names(dat)) {
      folder <- trimws(as.character(dat$folder))
      ifelse(!is.na(folder) & nzchar(folder), "aspm", NA_character_)
    } else {
      rep(NA_character_, nrow(dat))
    },
    rep(NA_character_, nrow(dat))
  )
  canonical_check_unit_values(values, ledger$type)
}

annotate_expected_check_units <- function(dat, ledger = expected_unit_ledger) {
  if (!is.data.frame(dat) || !nrow(dat) || !isTRUE(ledger$present)) return(dat)
  observed <- observed_check_unit_values(dat, ledger)
  dat$check_unit_type <- ledger$type
  dat$check_unit <- observed
  dat$unit <- observed
  if (identical(ledger$type, "aspm")) dat$aspm <- observed
  dat
}

add_missing_expected_check_units <- function(dat, ledger = expected_unit_ledger) {
  if (!isTRUE(ledger$present)) return(dat)
  observed <- observed_check_unit_values(dat, ledger)
  missing <- ledger$units[!ledger$units %in% observed[!is.na(observed)]]
  if (length(missing)) {
    missing_rows <- data.frame(
      check_type = check_type,
      check_unit_type = ledger$type,
      check_unit = missing,
      unit = missing,
      run_status = "missing",
      run_completed = FALSE,
      convergence_status = "not_completed",
      converged = FALSE,
      success = FALSE,
      failure_reason = paste0(
        "Expected ", ledger$type,
        " unit was not present in merged Kflow outputs: ", missing
      ),
      folder = NA_character_,
      stringsAsFactors = FALSE
    )
    unit_field <- switch(
      ledger$type,
      seed = "seed",
      peel = "peel",
      replicate = "rep",
      aspm = "aspm"
    )
    if (ledger$type %in% c("seed", "peel", "replicate")) {
      missing_rows[[unit_field]] <- suppressWarnings(as.integer(missing))
    } else {
      missing_rows[[unit_field]] <- missing
    }
    out <- bind_rows_fill_local(list(dat, missing_rows))
  } else {
    out <- dat
  }
  unit_order <- match(as.character(out$check_unit), ledger$units)
  out <- out[order(unit_order, na.last = TRUE), , drop = FALSE]
  rownames(out) <- NULL
  out
}

relative_to <- function(path, root = output_dir) {
  path <- normalize_loose(path)
  root <- normalize_loose(root)
  prefix <- paste0(root, "/")
  if (identical(path, root)) return(".")
  if (startsWith(path, prefix)) substring(path, nchar(prefix) + 1L) else path
}

discover_check_model_dirs <- function(root, check_type, include_unmanifested = FALSE) {
  root <- as.character(root %||% character())
  root <- root[!is.na(root) & nzchar(trimws(root))]
  if (!length(root)) return(character())
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
  if (isTRUE(include_unmanifested)) {
    check_roots <- unique(unlist(lapply(roots, function(one_root) {
      candidates <- list.dirs(one_root, recursive = TRUE, full.names = TRUE)
      candidates[
        basename(candidates) == check_type &
          basename(dirname(candidates)) == "checks"
      ]
    }), use.names = FALSE))
    unmanifested <- unique(unlist(lapply(check_roots, function(check_root) {
      candidates <- normalize_loose(list.dirs(check_root, recursive = FALSE, full.names = TRUE))
      candidates[dirname(candidates) == normalize_loose(check_root)]
    }), use.names = FALSE))
    dirs <- unique(c(dirs, unmanifested))
  }
  marker <- paste0("/checks/", check_type, "/")
  dirs <- dirs[grepl(marker, normalize_loose(dirs), fixed = TRUE)]
  # A prior merge can be present in an attached-output bundle.  It is a
  # derivative of profile side jobs, not an input unit for this merge, and
  # must not hide a failed current-side point with an older valid copy.
  dirs <- dirs[!vapply(dirs, function(dir) {
    manifest_file <- file.path(dir, "check_manifest.rds")
    manifest <- if (file.exists(manifest_file)) {
      tryCatch(readRDS(manifest_file), error = function(e) NULL)
    } else {
      NULL
    }
    is.list(manifest) && !is.null(manifest$source_model_dirs) &&
      length(manifest$source_model_dirs) &&
      nzchar(as.character(manifest$source_model_dirs[[1L]]))
  }, logical(1L))]
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
  for (par_file in list.files(source_dir, pattern = "[.]par$", full.names = TRUE, recursive = FALSE)) {
    copy_file_if_exists(par_file, target_dir)
  }
  copy_existing_diagnostic_dirs(source_dir, target_dir, exclude = check_type)
}

format_profile_scalar <- function(value) {
  value <- suppressWarnings(as.numeric(value[[1L]]))
  if (!is.finite(value)) return("100")
  if (abs(value - round(value)) < .Machine$double.eps^0.5) {
    as.character(as.integer(round(value)))
  } else {
    format(value, scientific = FALSE, trim = TRUE)
  }
}

profile_anchor_scalar <- function() {
  center <- split_numbers(env("PROFILE_CENTER", ""), default = numeric())
  if (length(center)) return(center[[1L]])
  values <- split_numbers(env("PROFILE_VALUES", env("MFK_SCALAR", "")), default = numeric())
  if (length(values)) return(values[[which.min(abs(values - 100))]])
  100
}

profile_payload_containers <- function(payload) {
  if (!is.list(payload)) return(list())
  out <- list(payload)
  frontier <- list(payload)
  for (depth in seq_len(3L)) {
    next_frontier <- list()
    for (container in frontier) {
      for (field in c(
        "data", "info", "fit", "model", "summary", "metadata",
        "diagnostics", "Diagnostics"
      )) {
        value <- tryCatch(container[[field]], error = function(e) NULL)
        if (is.list(value)) {
          out[[length(out) + 1L]] <- value
          next_frontier[[length(next_frontier) + 1L]] <- value
        }
      }
    }
    if (!length(next_frontier)) break
    frontier <- next_frontier
  }
  out
}

profile_payload_number <- function(payload, fields, default = NA_real_) {
  for (container in profile_payload_containers(payload)) {
    for (field in fields) {
      value <- suppressWarnings(as.numeric(
        tryCatch(container[[field]], error = function(e) NA_real_)
      ))
      value <- value[is.finite(value)]
      if (length(value)) return(value[[1L]])
    }
  }
  default
}

profile_payload_logical <- function(payload, fields, default = NA) {
  for (container in profile_payload_containers(payload)) {
    for (field in fields) {
      value <- tryCatch(container[[field]], error = function(e) NULL)
      if (is.null(value) || !length(value)) next
      parsed <- merge_profile_logical(value)
      if (!is.na(parsed)) return(parsed)
    }
  }
  default
}

profile_base_payload <- function(root) {
  path <- file.path(root, "model_payload.rds")
  if (!file.exists(path)) return(NULL)
  tryCatch(readRDS(path), error = function(e) NULL)
}

profile_base_par <- function(root) {
  candidates <- c(
    file.path(root, "final.par"),
    list.files(root, pattern = "[.]par$", full.names = TRUE, recursive = FALSE)
  )
  candidates <- unique(candidates[file.exists(candidates)])
  if (length(candidates)) candidates[[1L]] else NA_character_
}

profile_anchor_has_par <- function(scalar_dir) {
  candidates <- list.files(
    scalar_dir, pattern = "[.]par$", full.names = TRUE, recursive = FALSE
  )
  info <- tryCatch(
    readRDS(file.path(scalar_dir, "profile_point_info.rds")),
    error = function(e) list()
  )
  payload <- tryCatch(
    readRDS(file.path(scalar_dir, "profile_payload.rds")),
    error = function(e) list()
  )
  output_par <- merge_profile_text(merge_profile_value(
    info, payload, c("output_par", "par", "final_par"), NA_character_
  ))
  if (!is.na(output_par)) {
    candidates <- c(candidates, file.path(scalar_dir, basename(output_par)))
  }
  candidates <- unique(candidates[file.exists(candidates)])
  length(candidates) && any(file.info(candidates)$size > 0, na.rm = TRUE)
}

profile_valid_fitted_anchor <- function(
    scalar_dir, scalar, profile_name, base_quantity, obj_fun, base_par,
    scalar_is_percent) {
  if (!dir.exists(scalar_dir)) return(FALSE)
  metadata <- merge_profile_point_metadata(scalar_dir)
  info <- tryCatch(
    readRDS(file.path(scalar_dir, "profile_point_info.rds")),
    error = function(e) list()
  )
  payload <- tryCatch(
    readRDS(file.path(scalar_dir, "profile_payload.rds")),
    error = function(e) list()
  )
  anchor_par <- file.path(scalar_dir, "final.par")
  same_number <- function(left, right) {
    is.finite(left) && is.finite(right) &&
      isTRUE(all.equal(as.numeric(left), as.numeric(right), tolerance = 1e-10))
  }
  stored_number <- function(fields) {
    value <- profile_payload_number(info, fields)
    if (is.finite(value)) value else profile_payload_number(payload, fields)
  }
  stored_scalar <- stored_number("scalar")
  stored_base <- stored_number(c("reference_quantity", "base_quantity"))
  stored_obj <- stored_number(c("obj_fun", "total_nll", "objective"))
  stored_profile <- merge_profile_text(merge_profile_value(
    info, payload, c("profile", "profile_name"), NA_character_
  ))
  stored_percent <- profile_payload_logical(info, "scalar_is_percent", default = NA)
  if (is.na(stored_percent)) {
    stored_percent <- profile_payload_logical(
      payload, "scalar_is_percent", default = NA
    )
  }
  same_par <- file.exists(anchor_par) && file.exists(base_par) &&
    file.info(anchor_par)$size > 0 && file.info(base_par)$size > 0 &&
    identical(unname(tools::md5sum(anchor_par)), unname(tools::md5sum(base_par)))
  isTRUE(metadata$anchor) && isTRUE(metadata$valid) &&
    isTRUE(metadata$completed) && is.finite(metadata$nll) &&
    profile_anchor_has_par(scalar_dir) && same_par &&
    same_number(stored_scalar, scalar) && same_number(stored_base, base_quantity) &&
    same_number(stored_obj, obj_fun) && identical(stored_profile, profile_name) &&
    identical(stored_percent, scalar_is_percent)
}

profile_base_quantity <- function(root, quantity, Af172, Af173, Af174) {
  explicit <- split_numbers(env("PROFILE_BASE_QUANTITY", ""), default = numeric())
  if (length(explicit)) return(explicit[[1L]])
  if (requireNamespace("mfclkit", quietly = TRUE)) {
    value <- tryCatch(
      mfclkit::mfk_model_quantity(
        model_dir = root,
        quantity = quantity,
        Af172 = Af172,
        Af173 = Af173,
        Af174 = Af174,
        required = FALSE
      ),
      error = function(e) NA_real_
    )
    value <- suppressWarnings(as.numeric(value[[1L]]))
    if (is.finite(value)) return(value)
  }
  payload <- profile_base_payload(root)
  profile_payload_number(
    payload,
    c("actual_quantity", "avg_bio", "quantity_profile_actual"),
    default = NA_real_
  )
}

profile_first_point_row <- function(root) {
  scalar_dirs <- list.dirs(file.path(root, "profile"), recursive = TRUE, full.names = TRUE)
  scalar_dirs <- scalar_dirs[grepl("^scalar_", basename(scalar_dirs))]
  for (scalar_dir in scalar_dirs) {
    info <- tryCatch(
      readRDS(file.path(scalar_dir, "profile_point_info.rds")),
      error = function(e) NULL
    )
    row <- tryCatch(info$row, error = function(e) NULL)
    if (is.data.frame(row) && nrow(row)) return(row[1L, , drop = FALSE])
  }
  NULL
}

profile_row_text <- function(row, field, default = "") {
  if (!is.data.frame(row) || !nrow(row) || !field %in% names(row)) return(default)
  value <- as.character(row[[field]][[1L]])
  if (!length(value) || is.na(value) || !nzchar(trimws(value))) default else value
}

profile_row_number <- function(row, field, default = NA_real_) {
  if (!is.data.frame(row) || !nrow(row) || !field %in% names(row)) return(default)
  value <- suppressWarnings(as.numeric(row[[field]][[1L]]))
  if (length(value) && is.finite(value[[1L]])) value[[1L]] else default
}

profile_env_or_text <- function(name, fallback) {
  value <- trimws(Sys.getenv(name, unset = ""))
  if (nzchar(value)) value else fallback
}

profile_env_or_number <- function(name, fallback) {
  value <- split_numbers(Sys.getenv(name, unset = ""), default = numeric())
  if (length(value) && is.finite(value[[1L]])) value[[1L]] else fallback
}

profile_expected_values <- function() {
  values <- split_numbers(
    env("PROFILE_EXPECTED_VALUES", env("MFK_PROFILE_EXPECTED_VALUES", "")),
    default = numeric()
  )
  if (!length(values)) {
    values <- split_numbers(
      env("PROFILE_VALUES", env("MFK_PROFILE_VALUES", env("MFK_SCALAR", ""))),
      default = numeric()
    )
  }
  if (truthy(env("PROFILE_INCLUDE_BASE_ANCHOR", "true"), TRUE)) {
    center <- profile_anchor_scalar()
    if (is.finite(center) && !any(abs(values - center) <= 1e-10)) {
      values <- c(values, center)
    }
  }
  sort(unique(values[is.finite(values)]))
}

profile_add_missing_expected <- function(points) {
  expected <- profile_expected_values()
  if (!length(expected)) return(points)
  observed <- if (is.data.frame(points) && nrow(points) && "scalar" %in% names(points)) {
    suppressWarnings(as.numeric(points$scalar))
  } else {
    numeric()
  }
  missing <- expected[!vapply(expected, function(value) {
    any(is.finite(observed) & abs(observed - value) <= 1e-8)
  }, logical(1L))]
  if (!length(missing)) return(points)

  profile_name <- if (is.data.frame(points) && nrow(points) && "profile" %in% names(points)) {
    value <- as.character(points$profile[[1L]])
    if (!is.na(value) && nzchar(value)) value else env("PROFILE_NAME", "total_average_biomass")
  } else {
    env("PROFILE_NAME", "total_average_biomass")
  }
  missing_rows <- data.frame(
    profile = profile_name,
    scalar = missing,
    total_nll = NA_real_,
    profile_nll = NA_real_,
    penalized_nll = NA_real_,
    constraint_penalty = NA_real_,
    run_status = "missing_profile_point",
    run_completed = FALSE,
    convergence_status = "not_completed",
    converged = FALSE,
    point_valid = FALSE,
    target_attained = FALSE,
    failure_reason = paste0(
      "Expected profile scalar was not present in merged Kflow outputs: ", missing
    ),
    folder = NA_character_,
    stringsAsFactors = FALSE
  )
  bind_rows_fill_local(list(points, missing_rows))
}

write_merged_profile_spec <- function(root, points = NULL) {
  row <- profile_first_point_row(root)
  profile_name <- profile_env_or_text(
    "PROFILE_NAME", profile_row_text(row, "profile", "total_average_biomass")
  )
  profile_dir <- file.path(root, "profile", profile_name)
  dir.create(profile_dir, recursive = TRUE, showWarnings = FALSE)
  observed_values <- if (is.data.frame(points) && "scalar" %in% names(points)) {
    keep <- rep(TRUE, nrow(points))
    if ("run_status" %in% names(points)) {
      keep <- tolower(as.character(points$run_status)) != "missing_profile_point"
      keep[is.na(keep)] <- TRUE
    }
    values <- suppressWarnings(as.numeric(points$scalar[keep]))
    sort(unique(values[is.finite(values)]))
  } else {
    numeric()
  }
  spec <- list(
    version = env("PROFILE_SPEC_VERSION", "mfclkit.quantity-profile.v2"),
    profile = profile_name,
    label = profile_env_or_text("PROFILE_LABEL", profile_row_text(row, "label", profile_name)),
    quantity = profile_env_or_text("PROFILE_QUANTITY", profile_row_text(row, "quantity", "avg_bio")),
    quantity_type = as.integer(profile_env_or_number(
      "PROFILE_QUANTITY_TYPE", profile_row_number(row, "quantity_type", 2L)
    )),
    Af172 = as.integer(profile_env_or_number("PROFILE_AF172", profile_row_number(row, "Af172", 0L))),
    Af173 = as.integer(profile_env_or_number("PROFILE_AF173", profile_row_number(row, "Af173", 0L))),
    Af174 = as.integer(profile_env_or_number("PROFILE_AF174", profile_row_number(row, "Af174", 0L))),
    base_quantity = profile_row_number(row, "base_quantity", NA_real_),
    expected_values = profile_expected_values(),
    observed_values = observed_values,
    center = profile_anchor_scalar(),
    side = "merged",
    preset = env("PROFILE_PRESET", env("MFK_PROFILE_PRESET", NA_character_)),
    execution_mode = env(
      "PROFILE_EXECUTION_MODE", env("MFK_PROFILE_EXECUTION_MODE", "continuation")
    ),
    parallel_mode = env("PROFILE_PARALLEL_MODE", "chains"),
    doitall_penalty = suppressWarnings(as.numeric(env(
      "PROFILE_DOITALL_PENALTY", env("MFK_PROFILE_DOITALL_PENALTY", NA_character_)
    ))),
    doitall_script = env(
      "PROFILE_DOITALL_SCRIPT", env("MFK_PROFILE_DOITALL_SCRIPT", "doitall.sh")
    ),
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )
  saveRDS(spec, file.path(profile_dir, "profile_spec.rds"), compress = "xz")
  point_valid <- if (is.data.frame(points) && "point_valid" %in% names(points)) {
    suppressWarnings(as.logical(points$point_valid))
  } else {
    rep(NA, if (is.data.frame(points)) nrow(points) else 0L)
  }
  point_scalar <- if (is.data.frame(points) && "scalar" %in% names(points)) {
    suppressWarnings(as.numeric(points$scalar))
  } else {
    numeric()
  }
  invalid_values <- point_scalar[is.finite(point_scalar) & (is.na(point_valid) | !point_valid)]
  profile_status <- list(
    status = if (!length(setdiff(spec$expected_values, observed_values)) &&
                 !length(invalid_values)) "complete" else "incomplete",
    expected_values = spec$expected_values,
    observed_values = observed_values,
    missing_values = setdiff(spec$expected_values, observed_values),
    invalid_values = sort(unique(invalid_values)),
    n_expected = length(spec$expected_values),
    n_observed = length(observed_values),
    n_valid = sum(!is.na(point_valid) & point_valid),
    n_invalid = sum(is.na(point_valid) | !point_valid)
  )
  saveRDS(profile_status, file.path(profile_dir, "profile_status.rds"), compress = "xz")
  invisible(spec)
}

write_profile_base_anchor <- function(root) {
  if (!identical(check_type, "profile")) return(invisible(FALSE))
  if (!truthy(env("PROFILE_INCLUDE_BASE_ANCHOR", "true"), TRUE)) return(invisible(FALSE))
  profile_type <- tolower(trimws(env("PROFILE_TYPE", "quantity")))
  if (!identical(profile_type, "quantity")) return(invisible(FALSE))

  point_row <- profile_first_point_row(root)
  profile_name <- profile_env_or_text(
    "PROFILE_NAME", profile_row_text(point_row, "profile", "total_average_biomass")
  )
  quantity <- profile_env_or_text(
    "PROFILE_QUANTITY", profile_row_text(point_row, "quantity", "avg_bio")
  )
  profile_label <- profile_env_or_text(
    "PROFILE_LABEL", profile_row_text(point_row, "label", profile_name)
  )
  scalar <- profile_anchor_scalar()
  scalar_token <- format_profile_scalar(scalar)
  value_mode <- tolower(trimws(env("PROFILE_VALUE_MODE", "percent")))
  scalar_is_percent <- !identical(value_mode, "absolute")
  quantity_type <- as.integer(profile_env_or_number(
    "PROFILE_QUANTITY_TYPE", profile_row_number(point_row, "quantity_type", 2L)
  ))
  Af172 <- as.integer(profile_env_or_number(
    "PROFILE_AF172", profile_row_number(point_row, "Af172", 0L)
  ))
  Af173 <- as.integer(profile_env_or_number(
    "PROFILE_AF173", profile_row_number(point_row, "Af173", 0L)
  ))
  Af174 <- as.integer(profile_env_or_number(
    "PROFILE_AF174", profile_row_number(point_row, "Af174", 0L)
  ))
  base_quantity <- profile_env_or_number(
    "PROFILE_BASE_QUANTITY", profile_row_number(point_row, "base_quantity", NA_real_)
  )
  if (!is.finite(base_quantity)) {
    base_quantity <- profile_base_quantity(root, quantity, Af172, Af173, Af174)
  }
  profile_root <- file.path(root, "profile", profile_name)
  scalar_dir <- file.path(profile_root, paste0("scalar_", scalar_token))

  payload <- profile_base_payload(root)
  obj_fun <- profile_payload_number(payload, c("obj_fun", "total_nll", "objective"))
  max_grad <- profile_payload_number(payload, c("max_grad", "maximum_gradient"))
  fit_completed <- profile_payload_logical(
    payload, c("run_completed", "fit_completed", "completed"), default = NA
  )
  base_par <- profile_base_par(root)
  restored_par <- FALSE
  if (is.na(base_par) || !file.exists(base_par) || file.info(base_par)$size <= 0) {
    restored_path <- tempfile(
      pattern = ".profile-anchor-", tmpdir = root, fileext = ".par"
    )
    base_par <- tryCatch(
      restore_payload_artifact(
        file.path(root, "model_payload.rds"), "par", restored_path,
        required = FALSE
      ),
      error = function(e) {
        warning(
          "Could not restore fitted profile anchor PAR: ", conditionMessage(e),
          call. = FALSE
        )
        ""
      }
    )
    restored_par <- nzchar(base_par)
  }
  if (isTRUE(restored_par)) on.exit(unlink(base_par, force = TRUE), add = TRUE)
  completed_fit <- !isFALSE(fit_completed) && is.finite(obj_fun) &&
    is.finite(max_grad) && abs(max_grad) <= 0.001 &&
    is.finite(base_quantity) && nzchar(base_par) && file.exists(base_par) &&
    file.info(base_par)$size > 0
  if (!isTRUE(completed_fit)) {
    warning(
      "Fitted profile anchor was not replaced because the compact base fit or PAR was incomplete.",
      call. = FALSE
    )
    return(invisible(FALSE))
  }
  # Reuse only an anchor proven to represent this exact fitted model and
  # profile contract. A stale or side-job scalar PAR is replaced.
  if (profile_valid_fitted_anchor(
    scalar_dir, scalar, profile_name, base_quantity, obj_fun, base_par,
    scalar_is_percent
  )) return(invisible(FALSE))

  if (dir.exists(scalar_dir)) unlink(scalar_dir, recursive = TRUE, force = TRUE)
  dir.create(scalar_dir, recursive = TRUE, showWarnings = FALSE)
  for (name in c("model_payload.rds", "model_payload_manifest.json", "model_payload_manifest.csv")) {
    copy_file_if_exists(file.path(root, name), scalar_dir)
  }
  copy_file_if_exists(base_par, scalar_dir, "final.par")
  output_par <- "final.par"

  target_quantity <- if (!is.finite(base_quantity)) {
    NA_real_
  } else if (scalar_is_percent) {
    base_quantity * scalar / 100
  } else {
    scalar
  }
  native_target <- if (is.finite(target_quantity) && identical(quantity_type, 1L)) {
    round(target_quantity * 1000)
  } else if (is.finite(target_quantity)) {
    round(target_quantity)
  } else {
    NA_real_
  }
  effective_target <- if (identical(quantity_type, 1L) && is.finite(native_target)) {
    native_target / 1000
  } else {
    native_target
  }
  actual_quantity <- base_quantity
  target_rel_err <- if (is.finite(actual_quantity) && is.finite(effective_target) &&
                        abs(effective_target) > 0) {
    (actual_quantity - effective_target) / abs(effective_target)
  } else {
    NA_real_
  }
  target_attained <- is.finite(target_rel_err) && abs(target_rel_err) <= 0.001
  converged <- is.finite(max_grad) && abs(max_grad) <= 0.001
  point_valid <- is.finite(obj_fun) && target_attained && converged
  row <- data.frame(
    profile = profile_name,
    scalar = scalar,
    label = profile_label,
    type = "quantity",
    quantity = quantity,
    quantity_label = profile_label,
    quantity_type = quantity_type,
    quantity_target = target_quantity,
    base_quantity = base_quantity,
    Af172 = Af172,
    Af173 = Af173,
    Af174 = Af174,
    scalar_is_percent = scalar_is_percent,
    use_quantity_penalty = TRUE,
    stringsAsFactors = FALSE
  )
  info <- list(
    engine = "fitted_model_anchor",
    profile = profile_name,
    profile_set_key = profile_name,
    profile_set_label = profile_label,
    scalar = scalar,
    row = row,
    chain = FALSE,
    chain_index = 0L,
    chain_start_par = NA_character_,
    point_dir = normalize_loose(scalar_dir),
    total_nll = obj_fun,
    profile_nll = obj_fun,
    penalized_nll = obj_fun,
    constraint_penalty = 0,
    objective_source = "fitted_model_par",
    obj_fun = obj_fun,
    max_grad = max_grad,
    output_par = output_par,
    fitted_par_md5 = unname(tools::md5sum(base_par)),
    actual_quantity = actual_quantity,
    actual_quantity_source = if (is.finite(actual_quantity)) "fitted_model" else NA_character_,
    target_quantity = effective_target,
    target_rel_err = target_rel_err,
    target_attained = target_attained,
    point_valid = point_valid,
    run_status = if (point_valid) "completed" else "anchor_not_valid",
    run_completed = is.finite(obj_fun),
    convergence_status = if (converged) "converged" else "not_converged",
    converged = converged,
    failure_reason = if (point_valid) NA_character_ else
      "Fitted anchor lacks a finite objective, a measured target quantity, or convergence.",
    error = NA_character_,
    base_anchor = TRUE
  )
  profile_payload <- list(
    version = "v2",
    source = "kflow_fitted_model_anchor",
    created_at = as.character(Sys.time()),
    scalar_dir = normalize_loose(scalar_dir),
    scalar = scalar,
    profile = profile_name,
    profile_set_key = profile_name,
    profile_set_label = profile_label,
    quantity_label = profile_label,
    profile_type = "quantity",
    quantity = quantity,
    quantity_type = quantity_type,
    requested_target = target_quantity,
    native_target = native_target,
    reference_quantity = base_quantity,
    target_quantity = effective_target,
    actual_quantity = actual_quantity,
    actual_quantity_source = info$actual_quantity_source,
    target_rel_err = target_rel_err,
    target_attained = target_attained,
    avg_bio = if (identical(quantity_type, 2L)) actual_quantity else NA_real_,
    scalar_is_percent = scalar_is_percent,
    use_quantity_penalty = TRUE,
    Af172 = Af172,
    Af173 = Af173,
    Af174 = Af174,
    af172 = Af172,
    af173 = Af173,
    af174 = Af174,
    obj_fun = obj_fun,
    total_nll = obj_fun,
    profile_nll = obj_fun,
    penalized_nll = obj_fun,
    constraint_penalty = 0,
    objective_source = "fitted_model_par",
    max_grad = max_grad,
    output_par = output_par,
    fitted_par_md5 = info$fitted_par_md5,
    harvest_par = NA_character_,
    point_valid = point_valid,
    run_completed = info$run_completed,
    convergence_status = info$convergence_status,
    converged = converged,
    failure_reason = info$failure_reason,
    run_status = info$run_status,
    hessian_requested = FALSE,
    hessian_attempted = FALSE,
    hessian_ok = NA,
    hessian_status = NA_character_,
    hessian_reliability = "UNKNOWN",
    hessian_n_negative = NA_integer_,
    hessian_n_total = NA_integer_,
    lik_out = NULL,
    lik_raw = NULL,
    mfclkit = info
  )
  saveRDS(info, file.path(scalar_dir, "profile_point_info.rds"), compress = "xz")
  saveRDS(info, file.path(scalar_dir, "info.rds"), compress = "xz")
  saveRDS(profile_payload, file.path(scalar_dir, "profile_payload.rds"), compress = "xz")
  message("[checks] wrote base profile anchor scalar ", scalar_token, " from fitted model output")
  invisible(TRUE)
}

profile_hbase_merge_mode <- function() {
  truthy(env("PROFILE_HBASE_ENABLED", "false"), FALSE) ||
    identical(tolower(trimws(env("PROFILE_PARALLEL_MODE", ""))), "h-base")
}

repair_hbase_profile <- function(root, selected_base) {
  enabled <- profile_hbase_merge_mode()
  role <- tolower(trimws(env("PROFILE_HBASE_ROLE", "")))
  repair_passes <- as.integer(profile_env_or_number(
    "PROFILE_HBASE_REPAIR_PASSES", 2
  ))
  if (!isTRUE(enabled) || !role %in% c("", "merge") ||
      !is.finite(repair_passes) || repair_passes < 1L) {
    return(invisible(NULL))
  }
  if (!"mfk_repair_hbase_profile" %in% getNamespaceExports("mfclkit")) {
    warning("h-base merge repair requires an updated mfclkit.", call. = FALSE)
    return(invisible(NULL))
  }
  profile_roots <- list.dirs(file.path(root, "profile"), recursive = FALSE, full.names = TRUE)
  points <- bind_rows_fill_local(lapply(profile_roots, mfclkit::mfk_read_profile_points))
  points <- dedupe_profile_points(profile_add_missing_expected(points))
  center <- profile_anchor_scalar()
  tolerance <- profile_env_or_number("PROFILE_JAGGED_TOLERANCE", 0.1)
  blocks <- mfclkit::mfk_hbase_suspect_blocks(
    points, center = center, tolerance = tolerance
  )
  if (!length(blocks)) {
    saveRDS(
      list(status = "not_needed", points = points, created_at = as.character(Sys.time())),
      file.path(root, "hbase-repair-result.rds"), compress = "xz"
    )
    return(invisible(NULL))
  }
  if (!is.data.frame(selected_base) || !nrow(selected_base)) {
    warning("h-base repair skipped because the fitted base model was unavailable.", call. = FALSE)
    return(invisible(NULL))
  }

  result <- tryCatch({
    staged <- stage_selected_model(
      selected_base[seq_len(1L), , drop = FALSE],
      work_dir = file.path(output_dir, ".hbase-repair-work"),
      output_dir = file.path(output_dir, ".hbase-repair-stage")
    )
    row <- profile_first_point_row(root)
    value_mode <- tolower(trimws(env("PROFILE_VALUE_MODE", "percent")))
    values <- profile_expected_values()
    if (!length(values)) {
      values <- sort(unique(suppressWarnings(as.numeric(points$scalar))))
      values <- values[is.finite(values)]
    }
    profile_name <- profile_env_or_text(
      "PROFILE_NAME", profile_row_text(row, "profile", "total_average_biomass")
    )
    quantity <- profile_env_or_text(
      "PROFILE_QUANTITY", profile_row_text(row, "quantity", "avg_bio")
    )
    quantity_type <- as.integer(profile_env_or_number(
      "PROFILE_QUANTITY_TYPE", profile_row_number(row, "quantity_type", 2L)
    ))
    base_quantity <- profile_env_or_number(
      "PROFILE_BASE_QUANTITY", profile_row_number(row, "base_quantity", NA_real_)
    )
    if (!is.finite(base_quantity)) base_quantity <- NULL
    profile <- mfclkit::mfk_quantity_profile_from_model(
      model_dir = staged$case_dir,
      name = profile_name,
      values = values,
      quantity = quantity,
      quantity_type = quantity_type,
      base_quantity = base_quantity,
      target = if (identical(value_mode, "absolute")) values else NA_real_,
      scalar_is_percent = !identical(value_mode, "absolute"),
      Af172 = as.integer(profile_env_or_number(
        "PROFILE_AF172", profile_row_number(row, "Af172", 0L)
      )),
      Af173 = as.integer(profile_env_or_number(
        "PROFILE_AF173", profile_row_number(row, "Af173", 0L)
      )),
      Af174 = as.integer(profile_env_or_number(
        "PROFILE_AF174", profile_row_number(row, "Af174", 0L)
      )),
      penalty = 1e7,
      reps = 2000L,
      convergence_exponent = as.integer(profile_env_or_number(
        "PROFILE_CONVERGENCE_EXPONENT", -3
      ))
    )
    backend <- mfclkit::mfk_native_backend(
      program_path = env("PROGRAM_PATH", staged$program_path %||% "/home/mfcl/mfclo64")
    )
    repaired <- mfclkit::mfk_repair_hbase_profile(
      backend = backend,
      input_dir = staged$case_dir,
      model_dir = root,
      profile = profile,
      par = staged$start_par,
      frq = staged$frq,
      preset = env("PROFILE_PRESET", "three_stage"),
      center = center,
      penalties = split_numbers(env("PROFILE_PENALTIES", "100000 1000000 10000000")),
      reps = split_numbers(env("PROFILE_RAMP_REPS", "50 50 2000")),
      convergence_exponent = as.integer(profile_env_or_number(
        "PROFILE_CONVERGENCE_EXPONENT", -3
      )),
      max_grad_threshold = {
        value <- profile_env_or_number("PROFILE_MAX_GRAD_THRESHOLD", NA_real_)
        if (is.finite(value)) value else NULL
      },
      target_rel_tolerance = profile_env_or_number(
        "PROFILE_TARGET_REL_TOLERANCE", 0.001
      ),
      continuation_reps = as.integer(profile_env_or_number(
        "PROFILE_CONTINUATION_REPS", 1000
      )),
      jagged_tolerance = tolerance,
      repair_passes = repair_passes,
      max_repair_scalars = profile_env_or_number("PROFILE_MAX_JAGGED_REPAIRS", 6),
      cpus = as.integer(profile_env_or_number("PROFILE_HBASE_REPAIR_CPUS", 4)),
      memory_gb = profile_env_or_number("PROFILE_HBASE_REPAIR_MEMORY_GB", 32),
      memory_gb_per_worker = profile_env_or_number(
        "PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB", 8
      ),
      run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
    )
    repaired$status <- "completed"
    repaired$initial_suspect_blocks <- blocks
    repaired
  }, error = function(e) {
    warning("h-base profile repair failed: ", conditionMessage(e), call. = FALSE)
    list(status = "failed", error = conditionMessage(e), initial_suspect_blocks = blocks)
  })
  saveRDS(result, file.path(root, "hbase-repair-result.rds"), compress = "xz")
  invisible(result)
}

close_ordinary_profile <- function(root, selected_base) {
  if (!truthy(env("PROFILE_POST_MERGE_REPAIR", "true"), TRUE) ||
      profile_hbase_merge_mode()) {
    return(invisible(NULL))
  }
  result_path <- file.path(root, "profile", "profile-closure-result.rds")
  save_result <- function(result) {
    audit_path <- tryCatch(as.character(result$audit_path[[1L]]), error = function(e) "")
    if (!length(audit_path) || is.na(audit_path)) audit_path <- ""
    if (nzchar(audit_path) && !file.exists(audit_path)) {
      dir.create(dirname(audit_path), recursive = TRUE, showWarnings = FALSE)
      saveRDS(result, audit_path, compress = "xz")
    }
    saveRDS(result, result_path, compress = "xz")
    invisible(result)
  }
  if (!"mfk_close_quantity_profile" %in% getNamespaceExports("mfclkit")) {
    warning(
      "Post-merge profile closure requires an updated mfclkit; publishing the unclosed profile.",
      call. = FALSE
    )
    return(save_result(list(
      status = "api_unavailable", created_at = as.character(Sys.time())
    )))
  }
  if (!is.data.frame(selected_base) || !nrow(selected_base)) {
    warning(
      "Post-merge profile closure skipped because the fitted base model was unavailable.",
      call. = FALSE
    )
    return(save_result(list(
      status = "base_model_unavailable", created_at = as.character(Sys.time())
    )))
  }

  result <- tryCatch({
    direct_par <- profile_base_par(root)
    direct_frq <- list.files(
      root, pattern = "[.]frq$", full.names = TRUE, recursive = FALSE
    )
    # Never seed repair from an arbitrary profile-point PAR. If the root fitted
    # PAR is compacted, stage it from the selected fitted-model payload.
    staged <- if (nzchar(direct_par) && file.exists(direct_par) && length(direct_frq)) {
      list(
        case_dir = root,
        start_par = direct_par,
        frq = direct_frq[[1L]],
        program_path = env("PROGRAM_PATH", "/home/mfcl/mfclo64")
      )
    } else {
      stage_selected_model(
        selected_base[seq_len(1L), , drop = FALSE],
        work_dir = file.path(output_dir, ".profile-closure-work"),
        output_dir = file.path(output_dir, ".profile-closure-stage")
      )
    }
    profile_roots <- list.dirs(
      file.path(root, "profile"), recursive = FALSE, full.names = TRUE
    )
    points <- bind_rows_fill_local(lapply(
      profile_roots, mfclkit::mfk_read_profile_points
    ))
    points <- dedupe_profile_points(profile_add_missing_expected(points))
    row <- profile_first_point_row(root)
    values <- profile_expected_values()
    if (!length(values) && is.data.frame(points) && "scalar" %in% names(points)) {
      values <- sort(unique(suppressWarnings(as.numeric(points$scalar))))
      values <- values[is.finite(values)]
    }
    profile_name <- profile_env_or_text(
      "PROFILE_NAME", profile_row_text(row, "profile", "total_average_biomass")
    )
    quantity <- profile_env_or_text(
      "PROFILE_QUANTITY", profile_row_text(row, "quantity", "avg_bio")
    )
    quantity_type <- as.integer(profile_env_or_number(
      "PROFILE_QUANTITY_TYPE", profile_row_number(row, "quantity_type", 2L)
    ))
    base_quantity <- profile_env_or_number(
      "PROFILE_BASE_QUANTITY", profile_row_number(row, "base_quantity", NA_real_)
    )
    if (!is.finite(base_quantity)) base_quantity <- NULL
    value_mode <- tolower(trimws(env("PROFILE_VALUE_MODE", "percent")))
    profile <- mfclkit::mfk_quantity_profile_from_model(
      model_dir = staged$case_dir,
      name = profile_name,
      values = values,
      quantity = quantity,
      quantity_type = quantity_type,
      base_quantity = base_quantity,
      target = if (identical(value_mode, "absolute")) values else NA_real_,
      scalar_is_percent = !identical(value_mode, "absolute"),
      Af172 = as.integer(profile_env_or_number(
        "PROFILE_AF172", profile_row_number(row, "Af172", 0L)
      )),
      Af173 = as.integer(profile_env_or_number(
        "PROFILE_AF173", profile_row_number(row, "Af173", 0L)
      )),
      Af174 = as.integer(profile_env_or_number(
        "PROFILE_AF174", profile_row_number(row, "Af174", 0L)
      )),
      penalty = 1e7,
      reps = 2000L,
      convergence_exponent = as.integer(profile_env_or_number(
        "PROFILE_CONVERGENCE_EXPONENT", -3
      ))
    )
    convergence_exponent <- as.integer(profile_env_or_number(
      "PROFILE_CONVERGENCE_EXPONENT", -3
    ))
    if (!is.finite(convergence_exponent) || convergence_exponent >= 0L) {
      convergence_exponent <- -3L
    }
    repair_passes <- as.integer(profile_env_or_number(
      "PROFILE_JAGGED_REPAIR_PASSES",
      profile_env_or_number("PROFILE_HBASE_REPAIR_PASSES", 2)
    ))
    if (!is.finite(repair_passes) || repair_passes < 1L) repair_passes <- 2L
    max_scalars <- as.integer(profile_env_or_number(
      "PROFILE_MAX_JAGGED_REPAIRS", 8
    ))
    if (!is.finite(max_scalars) || max_scalars < 1L) max_scalars <- 6L
    max_runs <- as.integer(min(
      .Machine$integer.max,
      as.double(max_scalars) * (as.double(repair_passes) + 2)
    ))
    cpus <- as.integer(profile_env_or_number(
      "PROFILE_REPAIR_CPUS", profile_env_or_number("PROFILE_HBASE_REPAIR_CPUS", 4)
    ))
    if (!is.finite(cpus) || cpus < 1L) cpus <- 1L
    cpus_per_worker <- as.integer(profile_env_or_number(
      "PROFILE_REPAIR_CPUS_PER_WORKER",
      profile_env_or_number("PROFILE_HBASE_REPAIR_CPUS_PER_WORKER", 1)
    ))
    if (!is.finite(cpus_per_worker) || cpus_per_worker < 1L) cpus_per_worker <- 1L
    memory_gb <- profile_env_or_number(
      "PROFILE_REPAIR_MEMORY_GB",
      profile_env_or_number("PROFILE_HBASE_REPAIR_MEMORY_GB", 32)
    )
    memory_gb_per_worker <- profile_env_or_number(
      "PROFILE_REPAIR_MEMORY_PER_WORKER_GB",
      profile_env_or_number("PROFILE_HBASE_REPAIR_MEMORY_PER_WORKER_GB", 8)
    )
    backend <- mfclkit::mfk_native_backend(
      program_path = env("PROGRAM_PATH", staged$program_path %||% "/home/mfcl/mfclo64")
    )
    penalties <- split_numbers(env("PROFILE_PENALTIES", ""), default = numeric())
    reps <- split_numbers(env("PROFILE_RAMP_REPS", ""), default = numeric())
    closed <- mfclkit::mfk_close_quantity_profile(
      backend = backend,
      input_dir = staged$case_dir,
      model_dir = root,
      profile = profile,
      par = staged$start_par,
      frq = staged$frq,
      preset = env("PROFILE_PRESET", "robust_fast"),
      center = profile_anchor_scalar(),
      penalties = if (length(penalties)) penalties else NULL,
      reps = if (length(reps)) reps else NULL,
      search_threshold = 10^convergence_exponent,
      target_rel_tolerance = profile_env_or_number(
        "PROFILE_TARGET_REL_TOLERANCE", 0.001
      ),
      continuation_reps = as.integer(profile_env_or_number(
        "PROFILE_CONTINUATION_REPS", 1000
      )),
      jagged_tolerance = profile_env_or_number(
        "PROFILE_JAGGED_TOLERANCE", 0.1
      ),
      repair_passes = repair_passes,
      max_runs = max_runs,
      max_scalars = max_scalars,
      final_polish = TRUE,
      polish_threshold = 1e-4,
      parallel = truthy(
        env("PROFILE_REPAIR_PARALLEL", if (cpus > 1L) "true" else "false"),
        cpus > 1L
      ),
      cpus = cpus,
      cpus_per_worker = cpus_per_worker,
      memory_gb = memory_gb,
      memory_gb_per_worker = memory_gb_per_worker,
      run_messages = truthy(env("MFK_RUN_MESSAGES", "true"), TRUE)
    )
    suspects <- tryCatch(closed$after_qc$suspect_scalars, error = function(e) NA_real_)
    budget_exhausted <- isTRUE(closed$budget$run_budget_exhausted) ||
      isTRUE(closed$budget$scalar_budget_exhausted)
    unresolved <- any(is.finite(suppressWarnings(as.numeric(suspects)))) ||
      budget_exhausted
    closed$status <- if (unresolved) "incomplete" else "completed"
    closed$completed <- !unresolved
    closed$unresolved_suspect_scalars <- suppressWarnings(as.numeric(suspects))
    closed
  }, error = function(e) {
    warning("Post-merge profile closure failed: ", conditionMessage(e), call. = FALSE)
    list(
      status = "failed", error = conditionMessage(e),
      created_at = as.character(Sys.time())
    )
  })
  save_result(result)
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
          copied <- c(copied, copy_profile_point_checked(
            dir,
            file.path(target_dir, "profile", basename(profile_root), basename(dir))
          ))
        }
      }
    }
  } else if (identical(check_type, "aspm")) {
    for (src in source_dirs) {
      src_root <- file.path(src, "aspm")
      if (!dir.exists(src_root)) next
      copied <- c(copied, copy_dir_contents_checked(src_root, file.path(target_dir, "aspm")))
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

collect_aspm_status <- function(model_dir) {
  if (requireNamespace("mfclkit", quietly = TRUE) &&
      "mfk_collect_aspm" %in% getNamespaceExports("mfclkit")) {
    return(getExportedValue("mfclkit", "mfk_collect_aspm")(model_dir))
  }
  info_file <- file.path(model_dir, "aspm", "aspm_info.rds")
  if (!file.exists(info_file)) return(data.frame(stringsAsFactors = FALSE))
  info <- tryCatch(readRDS(info_file), error = function(e) NULL)
  if (is.null(info)) return(data.frame(stringsAsFactors = FALSE))
  data.frame(
    model = basename(normalize_loose(model_dir)),
    run_status = as.character(info$run_status %||% NA_character_),
    run_completed = isTRUE(info$run_completed),
    convergence_status = as.character(info$convergence_status %||% NA_character_),
    converged = isTRUE(info$converged),
    obj_fun = suppressWarnings(as.numeric(info$obj_fun %||% NA_real_)),
    max_grad = suppressWarnings(as.numeric(info$max_grad %||% NA_real_)),
    input_par = as.character(info$input_par %||% NA_character_),
    output_par = as.character(info$output_par %||% NA_character_),
    failure_reason = as.character(info$failure_reason %||% NA_character_),
    folder = normalize_loose(file.path(model_dir, "aspm")),
    stringsAsFactors = FALSE
  )
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
        "blocked_by_previous_profile_point", "missing_profile_point",
        "unknown", "status_collect_failed"
      ) | grepl("failed|error|not[-_ ]?converged|not[-_ ]?completed|blocked|missing", value)
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
  # Quantity profile output is only usable when the constraint target was
  # actually attained and the runner marked the point valid.  A process can
  # finish with a finite objective while failing either condition.
  if ("target_attained" %in% names(dat)) {
    target_attained <- suppressWarnings(as.logical(dat$target_attained))
    success <- success & !is.na(target_attained) & target_attained
  }
  if ("point_valid" %in% names(dat)) {
    point_valid <- suppressWarnings(as.logical(dat$point_valid))
    success <- success & !is.na(point_valid) & point_valid
  }
  if ("total_nll" %in% names(dat)) {
    total_nll <- suppressWarnings(as.numeric(dat$total_nll))
    success <- success & is.finite(total_nll)
  }
  success
}

dedupe_profile_points <- function(points) {
  if (!is.data.frame(points) || !nrow(points) || !all(c("profile", "scalar") %in% names(points))) {
    return(points)
  }
  points$.success_rank <- check_status_success(points)
  if ("run_status" %in% names(points)) {
    points$.anchor_rank <- tolower(as.character(points$run_status)) == "base_anchor"
  } else {
    points$.anchor_rank <- FALSE
  }
  if ("folder" %in% names(points)) {
    points$.folder_rank <- as.character(points$folder)
  } else {
    points$.folder_rank <- ""
  }
  points <- points[order(
    points$profile,
    suppressWarnings(as.numeric(points$scalar)),
    -as.integer(points$.anchor_rank),
    -as.integer(points$.success_rank),
    points$.folder_rank,
    na.last = TRUE
  ), , drop = FALSE]
  key <- paste(points$profile, suppressWarnings(as.numeric(points$scalar)), sep = "\r")
  out <- points[!duplicated(key), , drop = FALSE]
  out$.success_rank <- NULL
  out$.anchor_rank <- NULL
  out$.folder_rank <- NULL
  rownames(out) <- NULL
  out
}

collect_check_unit_status <- function(model_dir, check_type, source_dirs = character()) {
  out <- tryCatch({
    if (identical(check_type, "jitter")) {
      if (requireNamespace("mfclkit", quietly = TRUE)) {
        mfclkit::mfk_collect_jitter(model_dir)
      } else {
        data.frame(stringsAsFactors = FALSE)
      }
    } else if (identical(check_type, "retro")) {
      if (requireNamespace("mfclkit", quietly = TRUE)) {
        mfclkit::mfk_collect_retro(model_dir)
      } else {
        data.frame(stringsAsFactors = FALSE)
      }
    } else if (identical(check_type, "aspm")) {
      collect_aspm_status(model_dir)
    } else if (identical(check_type, "profile")) {
      if (requireNamespace("mfclkit", quietly = TRUE)) {
        roots <- list.dirs(file.path(model_dir, "profile"), recursive = FALSE, full.names = TRUE)
        profile_add_missing_expected(
          bind_rows_fill_local(lapply(roots, mfclkit::mfk_read_profile_points))
        )
      } else {
        data.frame(stringsAsFactors = FALSE)
      }
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
    warning(
      "Could not collect ", check_type, " unit status; using the source summary ",
      "or expected-unit ledger: ", conditionMessage(e),
      call. = FALSE
    )
    data.frame(stringsAsFactors = FALSE)
  })
  if ((!is.data.frame(out) || !nrow(out)) && !isTRUE(expected_unit_ledger$present)) {
    summaries <- lapply(source_dirs, function(src) {
      path <- file.path(src, "check-summary.csv")
      if (file.exists(path)) read_csv_safe(path) else data.frame(stringsAsFactors = FALSE)
    })
    out <- bind_rows_fill_local(summaries)
  }
  if (!is.data.frame(out)) out <- data.frame(stringsAsFactors = FALSE)
  if (nrow(out)) {
    out$check_type <- check_type
    if (identical(check_type, "profile")) {
      out <- dedupe_profile_points(out)
    }
    out <- annotate_expected_check_units(out)
    success <- check_status_success(out)
    if (length(success) != nrow(out)) success <- rep(FALSE, nrow(out))
    out$success <- success
  }
  out <- add_missing_expected_check_units(out)
  if (!nrow(out) && !length(source_dirs) && nzchar(base_input_job)) {
    out <- data.frame(
      check_type = check_type,
      check_unit_type = "job",
      check_unit = check_type,
      unit = check_type,
      run_status = "missing",
      run_completed = FALSE,
      convergence_status = "not_completed",
      converged = FALSE,
      success = FALSE,
      failure_reason = paste0(
        "No current ", check_type,
        " unit output was available to the merge job."
      ),
      folder = NA_character_,
      stringsAsFactors = FALSE
    )
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
  expected_profile_values <- if (identical(check_type, "profile")) profile_expected_values() else numeric()
  n_missing_expected <- if (n_units && "run_status" %in% names(units)) {
    missing_status <- if (identical(check_type, "profile")) "missing_profile_point" else "missing"
    if (identical(check_type, "profile") || isTRUE(expected_unit_ledger$present)) {
      sum(tolower(as.character(units$run_status)) == missing_status, na.rm = TRUE)
    } else {
      NA_integer_
    }
  } else if (identical(check_type, "profile") || isTRUE(expected_unit_ledger$present)) {
    0L
  } else {
    NA_integer_
  }
  requires_all_units <- check_type %in% c("hessian", "profile") || isTRUE(expected_unit_ledger$present)
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
    expected_unit_type = if (isTRUE(expected_unit_ledger$present)) expected_unit_ledger$type else NA_character_,
    expected_units = if (isTRUE(expected_unit_ledger$present)) paste(expected_unit_ledger$units, collapse = " ") else NA_character_,
    n_expected_units = if (identical(check_type, "profile")) {
      length(expected_profile_values)
    } else if (isTRUE(expected_unit_ledger$present)) {
      length(expected_unit_ledger$units)
    } else {
      NA_integer_
    },
    n_missing_expected = n_missing_expected,
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

merge_profile_row_metadata <- function(row) {
  value <- function(fields, default = NA) {
    for (field in fields) {
      if (!field %in% names(row)) next
      out <- row[[field]][[1L]]
      if (!merge_profile_missing(out)) return(out)
    }
    default
  }
  scalar <- merge_profile_number(value(c("scalar", "profile_scalar")))
  target_value <- value(c(
    "effective_target", "target_quantity", "quantity_target",
    "requested_target", "native_target", "target"
  ))
  target <- merge_profile_number(target_value)
  target_explicit <- is.finite(target)
  if (!target_explicit) target <- scalar
  source <- merge_profile_text(value("objective_source"))
  status <- merge_profile_text(value(c("run_status", "status")))
  list(
    dir = merge_profile_text(value(c("folder", "point_dir", "profile_dir"))),
    scalar = scalar,
    target = target,
    target_explicit = target_explicit,
    valid = isTRUE(merge_profile_logical(value(c("point_valid", "valid")))),
    completed = isTRUE(merge_profile_logical(value(c("run_completed", "completed")))) ||
      (!is.na(status) && status %in% c("completed", "complete", "success", "base_anchor")),
    converged = isTRUE(merge_profile_logical(value("converged"))),
    nll = merge_profile_number(value(c("profile_nll", "total_nll", "objective"))),
    anchor = isTRUE(merge_profile_logical(value("base_anchor"))) ||
      identical(source, "fitted_model_par") || identical(status, "base_anchor"),
    objective_source = source,
    objective_evaluation = merge_profile_text(value("objective_evaluation")),
    objective_comparison_key = merge_profile_text(value("objective_comparison_key")),
    objective_comparable = merge_profile_logical(value("objective_comparable")),
    profile_cache_signature = merge_profile_text(value("profile_cache_signature")),
    configuration = list(
      profile = merge_profile_text(value(c("profile", "profile_name"))),
      quantity_type = merge_profile_text(value("quantity_type")),
      quantity_name = merge_profile_text(value(c("quantity_name", "quantity_label"))),
      af172 = merge_profile_text(value(c("Af172", "af172", "af_172"))),
      af173 = merge_profile_text(value(c("Af173", "af173", "af_173"))),
      af174 = merge_profile_text(value(c("Af174", "af174", "af_174")))
    )
  )
}

dedupe_profile_points_unfiltered <- dedupe_profile_points
dedupe_profile_points <- function(points) {
  if (!is.data.frame(points) || nrow(points) < 2L || !"scalar" %in% names(points)) {
    return(dedupe_profile_points_unfiltered(points))
  }
  profile <- if ("profile" %in% names(points)) as.character(points$profile) else "profile"
  scalar <- suppressWarnings(as.numeric(points$scalar))
  key <- paste(profile, format(scalar, digits = 17L, scientific = FALSE), sep = "\r")
  key[!is.finite(scalar)] <- paste0("missing\r", which(!is.finite(scalar)))
  groups <- split(seq_len(nrow(points)), factor(key, levels = unique(key)))
  if (all(lengths(groups) == 1L)) return(dedupe_profile_points_unfiltered(points))
  selected_rows <- lapply(groups, function(indices) {
    selected <- points[indices[[1L]], , drop = FALSE]
    if (length(indices) == 1L) return(selected)
    for (index in indices[-1L]) {
      candidate <- points[index, , drop = FALSE]
      existing_meta <- merge_profile_row_metadata(selected)
      candidate_meta <- merge_profile_row_metadata(candidate)
      comparison <- merge_profile_candidate_comparability(candidate_meta, existing_meta)
      if (comparison$comparable) {
        selected <- dedupe_profile_points_unfiltered(rbind(selected, candidate))
        selected <- selected[seq_len(1L), , drop = FALSE]
        action <- "row_duplicate_comparable_selection"
      } else if (merge_profile_better_execution(
        merge_profile_execution_score(candidate_meta),
        merge_profile_execution_score(existing_meta)
      )) {
        selected <- candidate
        action <- "row_duplicate_better_execution"
      } else {
        action <- "row_duplicate_kept_existing_incomparable"
      }
      record_index <- length(profile_duplicate_records) + 1L
      profile_duplicate_records[[record_index]] <<- data.frame(
        source_dir = candidate_meta$dir,
        target_dir = existing_meta$dir,
        action = action,
        incoming_valid = candidate_meta$valid,
        existing_valid = existing_meta$valid,
        incoming_nll_rank = if (is.finite(candidate_meta$nll)) -candidate_meta$nll else -Inf,
        existing_nll_rank = if (is.finite(existing_meta$nll)) -existing_meta$nll else -Inf,
        stringsAsFactors = FALSE
      )
      merge_profile_add_provenance(
        record_index, comparison, candidate_meta, existing_meta,
        merge_profile_row_metadata(selected)
      )
    }
    selected
  })
  out <- bind_rows_fill_local(selected_rows)
  rownames(out) <- NULL
  out
}

merge_profile_vector_logical <- function(x) {
  vapply(as.list(x), function(value) isTRUE(merge_profile_logical(value)), logical(1L))
}

merge_profile_annotate_points <- function(points) {
  if (!is.data.frame(points) || !nrow(points)) return(points)
  required <- c(
    "objective_comparison_key", "objective_evaluation", "objective_source",
    "objective_comparable", "profile_cache_signature"
  )
  for (field in setdiff(required, names(points))) points[[field]] <- NA
  source <- trimws(as.character(points$objective_source))
  anchor <- !is.na(source) & source == "fitted_model_par"
  modern <- !is.na(points$objective_comparison_key) &
    nzchar(trimws(as.character(points$objective_comparison_key))) &
    !is.na(points$objective_evaluation) &
    nzchar(trimws(as.character(points$objective_evaluation))) &
    !is.na(source) & nzchar(source) &
    merge_profile_vector_logical(points$objective_comparable)
  points$profile_comparability <- ifelse(
    anchor, "fitted_anchor",
    ifelse(modern, "modern_metadata", "legacy_comparability_assumed")
  )
  points
}

merge_profile_diagnostics <- function(model_dir, points, profile_qc = data.frame()) {
  findings <- list()
  add <- function(
      code, level = "warning", scalar = NA_real_, detail = "",
      blocking = code %in% c(
        "missing_fitted_profile_anchor",
        "off_center_nll_below_fitted_anchor",
        "remaining_profile_spike"
      )) {
    findings[[length(findings) + 1L]] <<- data.frame(
      code = code, level = level, scalar = scalar, detail = detail,
      blocking = isTRUE(blocking), stringsAsFactors = FALSE
    )
  }
  duplicate_rows <- bind_rows_fill_local(profile_duplicate_records)
  if (nrow(duplicate_rows) && "profile_comparability" %in% names(duplicate_rows)) {
    markers <- as.character(duplicate_rows$profile_comparability)
    legacy <- !is.na(markers) & grepl("^legacy_", markers)
    if (any(legacy)) {
      add(
        "legacy_duplicate_comparability", "info", NA_real_,
        sprintf("%d duplicate comparison(s) used legacy assumptions", sum(legacy))
      )
    }
    for (index in which(!is.na(markers) & grepl("^incomparable", markers))) {
      code <- if (grepl("objective_source|zero_penalty", markers[[index]])) {
        "mixed_objective_source"
      } else {
        "mixed_objective_configuration"
      }
      add(code, "warning", NA_real_, markers[[index]])
    }
  }
  if (!is.data.frame(points) || !nrow(points)) {
    add("no_profile_points", "warning", NA_real_, "no merged profile points")
    return(bind_rows_fill_local(findings))
  }
  legacy <- points$profile_comparability == "legacy_comparability_assumed"
  legacy[is.na(legacy)] <- FALSE
  if (any(legacy)) {
    add(
      "legacy_payload_comparability", "info", NA_real_,
      sprintf("%d selected point(s) lack complete modern objective provenance", sum(legacy))
    )
  }
  valid <- if ("point_valid" %in% names(points)) {
    merge_profile_vector_logical(points$point_valid)
  } else {
    rep(FALSE, nrow(points))
  }
  for (index in which(!valid)) {
    add("invalid_profile_point", "warning", suppressWarnings(as.numeric(points$scalar[[index]])),
        "point_valid is not true; existing completion rules remain authoritative")
  }
  source <- trimws(as.character(points$objective_source))
  anchor <- !is.na(source) & source == "fitted_model_par"
  selected <- !anchor & valid
  sources <- unique(source[selected & !is.na(source) & nzchar(source)])
  if (length(sources) > 1L) {
    add("mixed_objective_source", "warning", NA_real_, paste(sources, collapse = ", "))
  }
  source_classes <- unique(vapply(sources, merge_profile_source_class, character(1L)))
  if (all(c("zero_penalty_harvest_par", "penalized_fallback") %in% source_classes)) {
    add(
      "zero_penalty_harvest_par_mixed_with_penalized_fallback", "warning",
      NA_real_, paste(sources, collapse = ", ")
    )
  }
  evaluations <- trimws(as.character(points$objective_evaluation[selected]))
  evaluations <- unique(evaluations[!is.na(evaluations) & nzchar(evaluations)])
  if (length(evaluations) > 1L) {
    add(
      "mixed_objective_configuration", "warning", NA_real_,
      paste("objective evaluation:", paste(evaluations, collapse = ", "))
    )
  }
  config_fields <- intersect(
    c("profile", "profile_name", "quantity_type", "quantity_name", "quantity_label",
      "Af172", "Af173", "Af174", "af172", "af173", "af174"),
    names(points)
  )
  for (field in config_fields) {
    values <- trimws(as.character(points[[field]][selected]))
    values <- unique(values[!is.na(values) & nzchar(values)])
    if (length(values) > 1L) {
      add(
        "mixed_profile_configuration", "warning", NA_real_,
        paste0(field, ": ", paste(values, collapse = ", "))
      )
    }
  }
  scalar <- suppressWarnings(as.numeric(points$scalar))
  nll_field <- intersect(c("profile_nll", "total_nll", "objective"), names(points))
  nll <- if (length(nll_field)) {
    suppressWarnings(as.numeric(points[[nll_field[[1L]]]]))
  } else {
    rep(NA_real_, nrow(points))
  }
  center <- tryCatch(profile_scalar_center(model_dir), error = function(e) NA_real_)
  if (!is.finite(center)) center <- profile_anchor_scalar()
  tolerance <- suppressWarnings(as.numeric(Sys.getenv(
    "PROFILE_NLL_MATERIAL_TOLERANCE", "0.1"
  )))
  if (!is.finite(tolerance) || tolerance < 0) tolerance <- 0.1
  anchor_rows <- which(anchor & valid & is.finite(nll))
  if (length(anchor_rows)) {
    anchor_distance <- abs(scalar[anchor_rows] - center)
    anchor_row <- if (any(is.finite(anchor_distance))) {
      anchor_rows[[which.min(replace(anchor_distance, !is.finite(anchor_distance), Inf))]]
    } else {
      anchor_rows[[1L]]
    }
    below <- which(
      valid & !anchor & is.finite(scalar) & is.finite(nll) &
        abs(scalar - center) > 1e-10 & nll < nll[[anchor_row]] - tolerance
    )
    for (index in below) {
      add(
        "off_center_nll_below_fitted_anchor", "critical", scalar[[index]],
        sprintf("off-center NLL %.10g; fitted anchor %.10g", nll[[index]], nll[[anchor_row]])
      )
    }
  } else {
    add("missing_fitted_profile_anchor", "critical", center,
        "no valid fitted-model objective anchor was retained")
  }
  profile_group <- if ("profile" %in% names(points)) {
    as.character(points$profile)
  } else {
    rep("profile", nrow(points))
  }
  rows_by_profile <- split(which(valid & is.finite(scalar) & is.finite(nll)), profile_group)
  for (rows in rows_by_profile) {
    rows <- rows[order(scalar[rows])]
    if (length(rows) < 3L) next
    for (offset in seq.int(2L, length(rows) - 1L)) {
      index <- rows[[offset]]
      neighbours <- nll[rows[c(offset - 1L, offset + 1L)]]
      high <- nll[[index]] > max(neighbours) + tolerance
      low <- is.finite(center) && abs(scalar[[index]] - center) > 1e-10 &&
        nll[[index]] < min(neighbours) - tolerance
      if (high || low) {
        add(
          "remaining_profile_spike", "critical", scalar[[index]],
          sprintf("NLL %.10g; adjacent %.10g and %.10g", nll[[index]], neighbours[[1L]], neighbours[[2L]])
        )
      }
    }
  }
  if (is.data.frame(profile_qc) && nrow(profile_qc)) {
    status_field <- intersect(c("qc", "status", "result"), names(profile_qc))
    if (length(status_field)) {
      status <- tolower(trimws(as.character(profile_qc[[status_field[[1L]]]])))
      for (index in which(status %in% c("bad", "fail", "failed", "error", "invalid"))) {
        detail_fields <- intersect(c("reason", "metric", "profile", "detail"), names(profile_qc))
        detail <- paste(
          unlist(profile_qc[index, detail_fields, drop = FALSE], use.names = FALSE),
          collapse = "; "
        )
        add("profile_shape_qc", "warning", NA_real_, detail)
      }
    }
  }
  closure_path <- file.path(model_dir, "profile", "profile-closure-result.rds")
  if (file.exists(closure_path)) {
    closure <- tryCatch(readRDS(closure_path), error = function(e) NULL)
    closure_status <- tolower(trimws(as.character(closure$status %||% "failed")))
    if (!identical(closure_status, "completed")) {
      stop_reason <- as.character(closure$stop_reason %||% closure$error %||% closure_status)
      suspects <- suppressWarnings(as.numeric(
        closure$unresolved_suspect_scalars %||% closure$after_qc$suspect_scalars
      ))
      suspects <- suspects[is.finite(suspects)]
      add(
        "profile_closure_incomplete", "critical",
        if (length(suspects)) suspects[[1L]] else NA_real_,
        paste0(
          "status=", closure_status, "; reason=", stop_reason,
          if (length(suspects)) paste0("; suspect scalars=", paste(suspects, collapse = ",")) else ""
        ),
        blocking = TRUE
      )
    }
  }
  out <- bind_rows_fill_local(findings)
  if (!nrow(out)) {
    out <- data.frame(
      code = character(), level = character(), scalar = numeric(),
      detail = character(), blocking = logical(), stringsAsFactors = FALSE
    )
  }
  unique(out)
}

merge_profile_finalize_diagnostics <- function(model_dir, points, profile_qc) {
  diagnostics <- merge_profile_diagnostics(model_dir, points, profile_qc)
  provenance <- bind_rows_fill_local(profile_duplicate_records)
  saveRDS(diagnostics, file.path(model_dir, "profile-merge-diagnostics.rds"))
  write.csv(diagnostics, file.path(model_dir, "profile-merge-diagnostics.csv"), row.names = FALSE)
  dir.create(file.path(model_dir, "profile"), recursive = TRUE, showWarnings = FALSE)
  saveRDS(
    diagnostics, file.path(model_dir, "profile", "profile-merge-diagnostics.rds")
  )
  write.csv(
    diagnostics, file.path(model_dir, "profile", "profile-merge-diagnostics.csv"),
    row.names = FALSE
  )
  saveRDS(profile_duplicate_records, file.path(model_dir, "profile-merge-provenance.rds"))
  write.csv(provenance, file.path(model_dir, "profile-merge-provenance.csv"), row.names = FALSE)
  invisible(diagnostics)
}

merge_profile_add_summary_diagnostics <- function(model_dir) {
  path <- file.path(model_dir, "profile-merge-diagnostics.rds")
  if (!file.exists(path)) return(invisible(NULL))
  diagnostics <- tryCatch(readRDS(path), error = function(e) data.frame())
  if (!is.data.frame(diagnostics)) return(invisible(NULL))
  warning_count <- sum(diagnostics$level == "warning", na.rm = TRUE)
  critical_count <- sum(diagnostics$level == "critical", na.rm = TRUE)
  blocking <- any(diagnostics$blocking %in% TRUE, na.rm = TRUE)
  fields <- list(
    profile_diagnostic_status = if (blocking || critical_count) {
      "critical"
    } else if (warning_count) {
      "warning"
    } else {
      "clear"
    },
    profile_diagnostic_count = warning_count + critical_count,
    profile_diagnostic_critical_count = critical_count,
    profile_diagnostics = paste(unique(diagnostics$code), collapse = ";"),
    profile_legacy_comparability = any(grepl("^legacy_", diagnostics$code), na.rm = TRUE),
    profile_diagnostics_blocking = blocking
  )
  rds_path <- file.path(model_dir, "check-summary.rds")
  if (file.exists(rds_path)) {
    summary <- tryCatch(readRDS(rds_path), error = function(e) NULL)
    if (is.list(summary)) {
      for (field in names(fields)) summary[[field]] <- fields[[field]]
      if (blocking) {
        summary$has_failures <- TRUE
        summary$all_required_units_successful <- FALSE
        summary$merge_status <- "incomplete"
      }
      saveRDS(summary, rds_path, compress = "xz")
    }
  }
  csv_path <- file.path(model_dir, "check-summary.csv")
  if (file.exists(csv_path)) {
    summary <- tryCatch(read.csv(csv_path, stringsAsFactors = FALSE), error = function(e) NULL)
    if (is.data.frame(summary)) {
      for (field in names(fields)) summary[[field]] <- fields[[field]]
      if (blocking) {
        summary$has_failures <- TRUE
        summary$all_required_units_successful <- FALSE
        summary$merge_status <- "incomplete"
      }
      write.csv(summary, csv_path, row.names = FALSE)
    }
  }
  invisible(fields)
}

write_check_status_summary_without_profile_diagnostics <- write_check_status_summary
write_check_status_summary <- function(model_dir, ...) {
  result <- write_check_status_summary_without_profile_diagnostics(model_dir, ...)
  merge_profile_add_summary_diagnostics(model_dir)
  invisible(result)
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
    aspm = "figure:aspm-diagnostics",
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
    aspm = "ASPM",
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
  species_code <- env("FLOW_SPECIES", "BET")
  species_label <- env("FLOW_SPECIES_LABEL", species_code)
  assessment_year <- env("FLOW_ASSESSMENT_YEAR", "2026")
  report_subject <- trimws(paste(assessment_year, species_label))
  result <- tryCatch(
    mfclshiny::build_app_report_figures(
      model_dir = dirname(model_dir),
      folders = model_dir,
      output_dir = out,
      title = paste(report_subject, check_type, "check figures"),
      formats = "png",
      build_payloads = FALSE,
      overwrite = TRUE,
      render_html = truthy(env("CHECK_RENDER_REVIEW_HTML", "false"), FALSE),
      qmd_file = "check-report.qmd",
      html_file = "check-report.html",
      figure_dir = "figures",
      table_dir = "tables",
      copy_legacy_root = FALSE,
      # Results bundles keep the canonical optimized PNG only. The check
      # review does not consume WebP/JPEG sidecars, so avoiding them saves
      # both export time and artifact storage.
      webp_figures = FALSE,
      pdf_jpeg_figures = FALSE,
      species_code = species_code,
      species_label = species_label,
      assessment_year = assessment_year,
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
  if (identical(check_type, "aspm")) {
    aspm_dir <- file.path(model_dir, "aspm")
    if (!dir.exists(aspm_dir)) return(invisible(data.frame()))
    tool_env <- mfclshiny_payload_tool_env("aspm")
    payload <- tool_env$mp_build_model_payload(aspm_dir)
    payload_file <- file.path(aspm_dir, "model_payload.rds")
    saveRDS(payload, payload_file, compress = "xz")
    if ("write_model_payload_manifest" %in% getNamespaceExports("mfclshiny")) {
      mfclshiny::write_model_payload_manifest(payload = payload, folder = aspm_dir, payload_file = payload_file)
    }
    return(invisible(data.frame(
      payload_role = "aspm_model_payload",
      folder = normalize_loose(aspm_dir),
      payload = normalize_loose(payload_file),
      stringsAsFactors = FALSE
    )))
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
        "aspm_info.rds",
        "aspm-index.csv",
        "aspm_control.txt",
        "run_aspm.sh",
        "aspm.par",
        "model_payload.rds",
        "model_payload_manifest.json",
        "model_payload_manifest.csv"
      ),
      keep_patterns = c(log_patterns, "(^|/)neigenvalues$", "[.]rep$"),
      recursive = TRUE
    ))
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

check_input_roots <- if (length(check_input_jobs)) {
  unique(unlist(lapply(
    check_input_jobs,
    function(job) input_job_dirs(input_root, job)
  ), use.names = FALSE))
} else {
  character()
}
source_search_roots <- if (length(check_input_jobs)) check_input_roots else input_root
source_model_dirs <- discover_check_model_dirs(
  source_search_roots,
  check_type,
  include_unmanifested = isTRUE(expected_unit_ledger$present)
)
source_model_dirs <- source_model_dirs[vapply(source_model_dirs, matches_model, logical(1), selector = model_selector)]
if (!length(source_model_dirs) && !isTRUE(expected_unit_ledger$present) &&
    !nzchar(base_input_job)) {
  stop("No ", check_type, " check model folders found under ", input_root, call. = FALSE)
}
if (!length(source_model_dirs)) {
  warning(
    "No ", check_type,
    " check model folders were published; writing the expected-unit failure ledger only.",
    call. = FALSE
  )
}

base_roots <- if (nzchar(base_input_job)) {
  input_job_dirs(input_root, base_input_job)
} else {
  character()
}
if (nzchar(base_input_job) && !length(base_roots)) {
  stop("Merge base input job directory was not found: ", base_input_job, call. = FALSE)
}
base_candidates <- bind_rows_fill_local(lapply(base_roots, discover_model_outputs))
base_selected <- if (nrow(base_candidates)) {
  tryCatch(
    select_model_output(base_candidates, model_selector),
    error = function(e) {
      stop("Could not select merge base model: ", conditionMessage(e), call. = FALSE)
    }
  )
} else {
  data.frame()
}
if (nzchar(base_input_job) && !nrow(base_selected)) {
  stop(
    "No model output matching ", shQuote(model_selector),
    " was found in merge base job ", base_input_job, ".",
    call. = FALSE
  )
}
base_model_dir <- if (nrow(base_selected)) {
  as.character(base_selected$compact_dir[[1L]] %||% "")
} else {
  ""
}

model_key_source <- if (nrow(base_selected)) {
  as.character(base_selected$model_key %||% model_selector)[[1L]]
} else if (length(source_model_dirs)) {
  basename(source_model_dirs[[1L]])
} else {
  model_selector
}
model_key <- gsub("[^A-Za-z0-9_.-]+", "_", model_key_source)
if (!nzchar(model_key)) model_key <- "model"
model_dir <- file.path(output_dir, "checks", check_type, model_key)
if (dir.exists(model_dir)) unlink(model_dir, recursive = TRUE, force = TRUE)
if (nzchar(base_model_dir) && dir.exists(base_model_dir)) {
  copy_dir(base_model_dir, model_dir)
  # Delta merges are independent overlays on the original fit. They publish
  # only their own diagnostic; Kflow composes the independent overlays.
  prepare_diagnostic_merge_base(model_dir, check_type, attach_output_mode)
} else {
  dir.create(model_dir, recursive = TRUE, showWarnings = FALSE)
  if (length(source_model_dirs)) copy_base_model_files(source_model_dirs[[1L]], model_dir)
}
copied <- copy_check_units(source_model_dirs, model_dir, check_type)
if (length(profile_duplicate_records)) {
  duplicates <- bind_rows_fill_local(profile_duplicate_records)
  write.csv(duplicates, file.path(model_dir, "profile-duplicate-points.csv"), row.names = FALSE)
  saveRDS(duplicates, file.path(model_dir, "profile-duplicate-points.rds"), compress = "xz")
}
if (identical(check_type, "profile")) {
  write_profile_base_anchor(model_dir)
  if (profile_hbase_merge_mode()) {
    repair_hbase_profile(model_dir, base_selected)
  } else {
    close_ordinary_profile(model_dir, base_selected)
  }
}

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
} else if (identical(check_type, "aspm")) {
  try(write.csv(collect_aspm_status(model_dir), file.path(model_dir, "aspm-index.csv"), row.names = FALSE), silent = TRUE)
} else if (identical(check_type, "profile")) {
  profile_roots <- list.dirs(file.path(model_dir, "profile"), recursive = FALSE, full.names = TRUE)
  points <- if (requireNamespace("mfclkit", quietly = TRUE)) {
    bind_rows_fill_local(lapply(profile_roots, mfclkit::mfk_read_profile_points))
  } else {
    data.frame(stringsAsFactors = FALSE)
  }
  points <- dedupe_profile_points(points)
  points <- profile_add_missing_expected(points)
  points <- dedupe_profile_points(points)
  points <- merge_profile_annotate_points(points)
  write.csv(points, file.path(model_dir, "profile-points.csv"), row.names = FALSE)
  write_merged_profile_spec(model_dir, points)
  profile_qc <- data.frame(stringsAsFactors = FALSE)
  if (nrow(points)) {
    profile_qc <- mfclkit::mfk_profile_conflict_metrics(points)
    missing_values <- points$scalar[tolower(as.character(points$run_status)) == "missing_profile_point"]
    if (length(missing_values)) {
      if (!nrow(profile_qc)) {
        profile_qc <- data.frame(
          profile = env("PROFILE_NAME", "total_average_biomass"),
          qc = "Bad",
          reason = "missing_expected_scalars",
          stringsAsFactors = FALSE
        )
      } else {
        profile_qc$qc <- "Bad"
        profile_qc$reason <- vapply(profile_qc$reason, function(reason) {
          existing <- as.character(reason)
          existing <- existing[!is.na(existing) & nzchar(existing)]
          paste(c(existing, "missing_expected_scalars"), collapse = ";")
        }, character(1L))
      }
      profile_qc$missing_expected_scalars <- paste(missing_values, collapse = " ")
    }
    write.csv(profile_qc, file.path(model_dir, "profile-qc.csv"), row.names = FALSE)
  }
  merge_profile_finalize_diagnostics(model_dir, points, profile_qc)
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
index <- if (nrow(base_selected)) {
  base_selected[seq_len(1L), , drop = FALSE]
} else {
  bind_rows_fill_local(rows)
}
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
if (".candidate_score" %in% names(index)) index$.candidate_score <- NULL
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
  base_model_dir = normalize_loose(base_model_dir),
  base_input_job = base_input_job,
  original_base_input_job = original_base_input_job,
  check_input_jobs = paste(check_input_jobs, collapse = " "),
  attach_output_mode = attach_output_mode,
  source_model_dirs = paste(source_model_dirs, collapse = " "),
  n_source_model_dirs = length(source_model_dirs),
  expected_unit_type = if (isTRUE(expected_unit_ledger$present)) expected_unit_ledger$type else NA_character_,
  expected_units = if (isTRUE(expected_unit_ledger$present)) paste(expected_unit_ledger$units, collapse = " ") else NA_character_,
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
copy_diagnostic_status_ledger(model_dir, check_type)
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
final_summary <- tryCatch(
  readRDS(file.path(model_dir, "check-summary.rds")),
  error = function(e) NULL
)
requires_all_units <- isTRUE(final_summary$requires_all_units %||% FALSE)
all_required_ok <- isTRUE(final_summary$all_required_units_successful %||% FALSE)
merge_status <- as.character(final_summary$merge_status %||% "incomplete")

if (length(source_model_dirs) || (nzchar(base_model_dir) && dir.exists(base_model_dir))) {
  write_attached_model_output(
    check_model_dir = model_dir,
    output_dir = output_dir,
    model_key = model_key,
    index = index,
    check_type = check_type,
    source_check_dirs = source_model_dirs,
    output_mode = attach_output_mode
  )
} else {
  message("[checks] skipped attached model output because neither a merge base nor a source check model was published")
}
message("[checks] merged ", check_type, " outputs under ", model_dir)

if (isTRUE(requires_all_units) && !isTRUE(all_required_ok)) {
  message("[checks] merged ", check_type, " outputs with incomplete required unit(s): ", merge_status)
}
