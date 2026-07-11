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

profile_payload_number <- function(payload, fields, default = NA_real_) {
  if (!is.list(payload)) return(default)
  for (field in fields) {
    value <- suppressWarnings(as.numeric(tryCatch(payload[[field]], error = function(e) NA_real_)))
    value <- value[is.finite(value)]
    if (length(value)) return(value[[1L]])
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
    if (!is.na(value) && nzchar(value)) value else env("PROFILE_NAME", "adult_biomass")
  } else {
    env("PROFILE_NAME", "adult_biomass")
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
    "PROFILE_NAME", profile_row_text(row, "profile", "adult_biomass")
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
    "PROFILE_NAME", profile_row_text(point_row, "profile", "adult_biomass")
  )
  quantity <- profile_env_or_text(
    "PROFILE_QUANTITY", profile_row_text(point_row, "quantity", "avg_bio")
  )
  profile_label <- profile_env_or_text(
    "PROFILE_LABEL", profile_row_text(point_row, "label", profile_name)
  )
  scalar <- profile_anchor_scalar()
  scalar_token <- format_profile_scalar(scalar)
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
  target_quantity <- if (is.finite(base_quantity)) base_quantity * scalar / 100 else NA_real_
  payload <- profile_base_payload(root)
  obj_fun <- profile_payload_number(payload, "obj_fun")
  max_grad <- profile_payload_number(payload, "max_grad")
  base_par <- profile_base_par(root)

  profile_root <- file.path(root, "profile", profile_name)
  scalar_dir <- file.path(profile_root, paste0("scalar_", scalar_token))
  # A direct, non-split mfclkit run has already written a fully audited anchor.
  # Never replace it with merge-side metadata.
  if (dir.exists(scalar_dir)) return(invisible(FALSE))
  dir.create(scalar_dir, recursive = TRUE, showWarnings = FALSE)
  for (name in c("model_payload.rds", "model_payload_manifest.json", "model_payload_manifest.csv")) {
    copy_file_if_exists(file.path(root, name), scalar_dir)
  }
  output_par <- NA_character_
  if (file.exists(base_par)) {
    copy_file_if_exists(base_par, scalar_dir)
    output_par <- basename(base_par)
  }

  target_quantity <- if (is.finite(base_quantity)) base_quantity * scalar / 100 else NA_real_
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
    scalar_is_percent = TRUE,
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
    scalar_is_percent = TRUE,
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
    data.frame(
      run_status = "status_collect_failed",
      run_completed = FALSE,
      converged = FALSE,
      failure_reason = conditionMessage(e),
      stringsAsFactors = FALSE
    )
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
  write.csv(points, file.path(model_dir, "profile-points.csv"), row.names = FALSE)
  write_merged_profile_spec(model_dir, points)
  if (nrow(points)) {
    profile_qc <- mfclkit::mfk_profile_conflict_metrics(points)
    missing_values <- points$scalar[tolower(as.character(points$run_status)) == "missing_profile_point"]
    if (length(missing_values)) {
      if (!nrow(profile_qc)) {
        profile_qc <- data.frame(
          profile = env("PROFILE_NAME", "adult_biomass"),
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
