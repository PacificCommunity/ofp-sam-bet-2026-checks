`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0) return(y)
  if (length(x) == 1L && is.na(x)) return(y)
  if (length(x) == 1L && !nzchar(as.character(x))) return(y)
  x
}

env <- function(name, default = "") {
  value <- Sys.getenv(name, unset = NA_character_)
  if (is.na(value) || !nzchar(value)) default else value
}

truthy <- function(value, default = FALSE) {
  if (is.null(value) || !length(value) || !nzchar(as.character(value[[1L]]))) {
    return(isTRUE(default))
  }
  tolower(trimws(as.character(value[[1L]]))) %in% c("1", "true", "yes", "y", "on")
}

split_values <- function(value, default = character()) {
  if (is.null(value) || !length(value) || !nzchar(as.character(value[[1L]]))) {
    return(default)
  }
  out <- unlist(strsplit(as.character(value), "[,[:space:]]+", perl = TRUE), use.names = FALSE)
  out[nzchar(out)]
}

split_numbers <- function(value, default = numeric()) {
  out <- suppressWarnings(as.numeric(split_values(value)))
  out <- out[is.finite(out)]
  if (length(out)) out else default
}

is_absolute_path <- function(path) {
  grepl("^(/|[A-Za-z]:[\\\\/])", path)
}

normalize_loose <- function(path) {
  normalizePath(path, winslash = "/", mustWork = FALSE)
}

copy_dir <- function(from, to) {
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

diagnostic_dir_names <- function() {
  c("jitter", "retro", "hessian", "profile", "selftest", "aspm", "projection")
}

copy_existing_diagnostic_dirs <- function(from, to, exclude = character()) {
  if (!dir.exists(from)) return(invisible(character()))
  exclude <- gsub("_", "-", tolower(as.character(exclude)))
  copied <- character()
  for (name in diagnostic_dir_names()) {
    if (gsub("_", "-", tolower(name)) %in% exclude) next
    source <- file.path(from, name)
    if (!dir.exists(source)) next
    target <- file.path(to, name)
    if (dir.exists(target)) unlink(target, recursive = TRUE, force = TRUE)
    copied <- c(copied, copy_dir(source, target))
  }
  invisible(copied)
}

write_attached_model_output <- function(check_model_dir,
                                        output_dir,
                                        model_key,
                                        index = data.frame(),
                                        check_type = env("CHECK_TYPE", ""),
                                        source_check_dirs = character()) {
  if (!dir.exists(check_model_dir)) {
    stop("Check model directory not found: ", check_model_dir, call. = FALSE)
  }
  model_key <- gsub("[^A-Za-z0-9_.-]+", "_", as.character(model_key %||% "model"))
  if (!nzchar(model_key)) model_key <- "model"
  target_dir <- file.path(output_dir, "models", model_key)
  copy_dir(check_model_dir, target_dir)

  attached <- data.frame(
    check_type = check_type,
    source_check_dir = normalize_loose(check_model_dir),
    attached_model_dir = normalize_loose(target_dir),
    source_check_dirs = paste(normalize_loose(source_check_dirs), collapse = " "),
    attached_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  write.csv(attached, file.path(output_dir, "attached-checks-index.csv"), row.names = FALSE)
  write.csv(attached, file.path(target_dir, "attached-checks-index.csv"), row.names = FALSE)
  saveRDS(attached, file.path(target_dir, "attached-checks-index.rds"), compress = "xz")

  index <- as.data.frame(index %||% data.frame(), stringsAsFactors = FALSE)
  if (!nrow(index)) {
    index <- data.frame(
      model_key = model_key,
      model_label = model_key,
      step_id = model_key,
      stringsAsFactors = FALSE
    )
  }
  index <- index[seq_len(1L), , drop = FALSE]
  index$model_dir <- file.path("models", model_key)
  index$model_folder <- model_key
  index$attached_checks <- TRUE
  index$attached_check_type <- check_type
  index$attached_at <- attached$attached_at[[1L]]
  index$attached_model_dir <- normalize_loose(target_dir)
  write.csv(index, file.path(output_dir, "model-index.csv"), row.names = FALSE)

  manifest <- data.frame(
    schema = "ofp-sam.checks.attached-model-bundle.v1",
    created_at = attached$attached_at[[1L]],
    model_key = model_key,
    check_type = check_type,
    check_model_dir = normalize_loose(check_model_dir),
    attached_model_dir = normalize_loose(target_dir),
    stringsAsFactors = FALSE
  )
  write.csv(manifest, file.path(output_dir, "attached-model-bundle.csv"), row.names = FALSE)
  saveRDS(as.list(manifest), file.path(output_dir, "attached-model-bundle.rds"), compress = "xz")
  invisible(target_dir)
}

bind_rows_fill <- function(rows) {
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

case_files <- function(path, pattern) {
  if (!dir.exists(path)) return(character())
  list.files(path, pattern = pattern, full.names = TRUE, ignore.case = TRUE)
}

latest_file <- function(files) {
  files <- files[file.exists(files)]
  if (!length(files)) return("")
  info <- file.info(files)
  normalize_loose(rownames(info)[which.max(info$mtime)])
}

latest_par <- function(path) {
  priority <- c("*finalmle.par", "*finalz.par", "*finalzz.par", "*finaly.par", "*finalx.par", "*final.par")
  for (pattern in priority) {
    hits <- list.files(path, pattern = glob2rx(pattern), full.names = TRUE, ignore.case = TRUE)
    if (length(hits)) return(latest_file(hits))
  }
  latest_file(case_files(path, "[.]par[0-9]*$"))
}

has_full_case <- function(path) {
  dir.exists(path) &&
    length(case_files(path, "[.]frq$")) > 0L &&
    (length(case_files(path, "[.]par[0-9]*$")) > 0L || length(case_files(path, "[.]ini$")) > 0L)
}

read_csv_safe <- function(path) {
  tryCatch(read.csv(path, stringsAsFactors = FALSE, check.names = FALSE), error = function(e) data.frame())
}

candidate_key <- function(row) {
  values <- c(
    row$step_id %||% "",
    row$model_label %||% "",
    row$job_key %||% "",
    row$model_key %||% "",
    row$model_name %||% "",
    basename(row$model_dir %||% ""),
    basename(row$source_dir %||% ""),
    basename(row$model_source %||% "")
  )
  values <- values[nzchar(values)]
  if (length(values)) values[[1L]] else paste0("model-", row$candidate_id %||% "")
}

discover_index_candidates <- function(root) {
  index_files <- list.files(root, pattern = "^model-index[.]csv$", recursive = TRUE, full.names = TRUE)
  rows <- list()
  for (index in index_files) {
    dat <- read_csv_safe(index)
    if (!nrow(dat)) next
    base <- dirname(index)
    for (i in seq_len(nrow(dat))) {
      row <- dat[i, , drop = FALSE]
      step_id <- as.character(row$step_id %||% "")
      model_dir <- as.character(row$model_dir %||% "")
      compact_dir <- if (nzchar(model_dir)) {
        if (is_absolute_path(model_dir)) model_dir else file.path(base, model_dir)
      } else if (nzchar(step_id)) {
        file.path(base, "models", step_id)
      } else {
        base
      }
      rows[[length(rows) + 1L]] <- data.frame(
        candidate_type = "indexed",
        candidate_id = length(rows) + 1L,
        index_file = normalize_loose(index),
        compact_dir = normalize_loose(compact_dir),
        stringsAsFactors = FALSE,
        row,
        check.names = FALSE
      )
    }
  }
  bind_rows_fill(rows)
}

discover_full_case_candidates <- function(root) {
  frq_files <- list.files(root, pattern = "[.]frq$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
  dirs <- unique(dirname(frq_files))
  dirs <- dirs[vapply(dirs, has_full_case, logical(1))]
  rows <- lapply(seq_along(dirs), function(i) {
    dir <- dirs[[i]]
    data.frame(
      candidate_type = "full_case",
      candidate_id = i,
      compact_dir = normalize_loose(dir),
      source_dir = normalize_loose(dir),
      step_id = basename(dir),
      model_label = basename(dir),
      model_source = "",
      final_par = basename(latest_par(dir)),
      stringsAsFactors = FALSE
    )
  })
  bind_rows_fill(rows)
}

discover_model_outputs <- function(root) {
  root <- normalize_loose(root)
  rows <- bind_rows_fill(list(
    discover_index_candidates(root),
    discover_full_case_candidates(root)
  ))
  if (!nrow(rows)) return(rows)
  rows$model_key <- vapply(seq_len(nrow(rows)), function(i) candidate_key(rows[i, , drop = FALSE]), character(1))
  rows
}

matches_selector <- function(row, selector) {
  if (!nzchar(selector)) return(TRUE)
  fields <- c(
    "step_id", "model_label", "job_key", "model_key", "model_name",
    "model_source", "source_dir", "compact_dir"
  )
  values <- unlist(row[intersect(fields, names(row))], use.names = FALSE)
  values <- unique(as.character(values[!is.na(values)]))
  basenames <- basename(values[nzchar(values)])
  values <- unique(c(values, basenames))
  if (selector %in% values) return(TRUE)
  any(grepl(selector, values, ignore.case = TRUE))
}

select_model_output <- function(candidates, selector = env("MODEL_SELECTOR", "")) {
  if (!nrow(candidates)) {
    stop("No model outputs found. Provide MODEL_INPUT_ROOT or Kflow input artifacts.", call. = FALSE)
  }
  keep <- vapply(seq_len(nrow(candidates)), function(i) {
    matches_selector(candidates[i, , drop = FALSE], selector)
  }, logical(1))
  hits <- candidates[keep, , drop = FALSE]
  if (!nrow(hits)) {
    stop("No model output matched MODEL_SELECTOR=", shQuote(selector), call. = FALSE)
  }
  if (nrow(hits) > 1L) {
    labels <- paste(hits$model_key, hits$compact_dir, sep = " -> ")
    stop(
      "MODEL_SELECTOR matched multiple outputs. Be more specific:\n",
      paste(utils::head(labels, 20L), collapse = "\n"),
      call. = FALSE
    )
  }
  hits[1L, , drop = FALSE]
}

default_input_root <- function() {
  explicit <- env("MODEL_INPUT_ROOT", "")
  if (nzchar(explicit)) return(explicit)
  candidates <- c(
    env("KFLOW_INPUT_DIR", ""),
    file.path(env("CHECK_TYPE", ""), "inputs"),
    file.path(env("CHECK_TYPE", ""), "input"),
    "inputs",
    "input",
    file.path("work", "inputs"),
    "."
  )
  hit <- candidates[nzchar(candidates) & dir.exists(candidates)]
  if (length(hit)) hit[[1L]] else "."
}

github_token <- function() {
  for (name in c("GITHUB_PAT", "GIT_PAT", "GH_TOKEN", "GITHUB_TOKEN", "KFLOW_GITHUB_TOKEN", "KFLOW_PERSONAL_TOKEN")) {
    value <- env(name, "")
    if (nzchar(value)) return(value)
  }
  ""
}

git_clone_repo <- function(repo, ref, dest) {
  if (!nzchar(repo)) stop("MODEL_SOURCE_REPO is required for compact model outputs.", call. = FALSE)
  if (dir.exists(dest)) unlink(dest, recursive = TRUE, force = TRUE)
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  url <- if (grepl("^(https://|git@)", repo)) repo else paste0("https://github.com/", repo, ".git")
  token <- github_token()
  askpass <- ""
  on.exit(if (nzchar(askpass)) unlink(askpass, force = TRUE), add = TRUE)
  git_env <- character()
  if (nzchar(token)) {
    askpass <- tempfile("checks-git-askpass-")
    writeLines(c(
      "#!/bin/sh",
      "case \"$1\" in",
      "  *Username*) printf '%s\\n' x-access-token ;;",
      "  *) printf '%s\\n' \"$KFLOW_GIT_ASKPASS_TOKEN\" ;;",
      "esac"
    ), askpass, useBytes = TRUE)
    Sys.chmod(askpass, mode = "0700")
    git_env <- c(
      paste0("GIT_ASKPASS=", askpass),
      "GIT_TERMINAL_PROMPT=0",
      paste0("KFLOW_GIT_ASKPASS_TOKEN=", token)
    )
  }
  args <- c("clone", "--quiet", "--depth", "1", "--branch", ref, url, dest)
  status <- system2("git", args, env = git_env)
  if (!identical(as.integer(status), 0L)) {
    unlink(dest, recursive = TRUE, force = TRUE)
    status <- system2("git", c("clone", "--quiet", "--depth", "50", url, dest), env = git_env)
    if (!identical(as.integer(status), 0L)) stop("git clone failed for ", repo, call. = FALSE)
    status <- system2("git", c("-C", dest, "checkout", "--quiet", ref), env = git_env)
    if (!identical(as.integer(status), 0L)) {
      status <- system2("git", c("-C", dest, "fetch", "--quiet", "--depth", "1", "origin", ref), env = git_env)
      if (!identical(as.integer(status), 0L)) stop("git fetch failed for ", repo, "@", ref, call. = FALSE)
      status <- system2("git", c("-C", dest, "checkout", "--quiet", "FETCH_HEAD"), env = git_env)
      if (!identical(as.integer(status), 0L)) stop("git checkout failed for ", repo, "@", ref, call. = FALSE)
    }
  }
  normalize_loose(dest)
}

resolve_source_case <- function(row, source_root) {
  override <- env("MODEL_SOURCE_PATH", "")
  source_path <- override %||% as.character(row$model_source %||% "")
  step_id <- as.character(row$step_id %||% "")
  candidates <- character()
  if (nzchar(source_path)) {
    candidates <- c(candidates, if (is_absolute_path(source_path)) source_path else file.path(source_root, source_path))
  }
  if (nzchar(step_id)) candidates <- c(candidates, file.path(source_root, "steps", step_id, "model"))
  candidates <- unique(normalize_loose(candidates))
  hits <- candidates[dir.exists(candidates)]
  if (!length(hits)) {
    stop("Could not resolve source case for selected model. Tried: ", paste(candidates, collapse = ", "), call. = FALSE)
  }
  hits[[1L]]
}

find_final_par <- function(row) {
  compact_dir <- as.character(row$compact_dir %||% "")
  final_name <- env("MODEL_FINAL_PAR", as.character(row$final_par %||% "final.par"))
  candidates <- c(
    if (nzchar(final_name) && is_absolute_path(final_name)) final_name else file.path(compact_dir, final_name),
    file.path(compact_dir, "final.par"),
    latest_par(compact_dir)
  )
  candidates <- unique(candidates[nzchar(candidates)])
  hit <- candidates[file.exists(candidates)]
  if (length(hit)) normalize_loose(hit[[1L]]) else ""
}

stage_selected_model <- function(row, work_dir = env("WORK_DIR", "work"), output_dir = env("OUTPUT_DIR", "outputs")) {
  stage_dir <- file.path(work_dir, "case")
  source_root <- ""
  compact_dir <- as.character(row$compact_dir %||% "")
  full_case <- identical(as.character(row$candidate_type %||% ""), "full_case") && has_full_case(compact_dir)

  if (isTRUE(full_case)) {
    source_case <- compact_dir
  } else {
    repo <- env("MODEL_SOURCE_REPO", "")
    ref <- env("MODEL_SOURCE_REF", "main")
    source_root <- env("MODEL_SOURCE_ROOT", "")
    if (!nzchar(source_root)) {
      source_root <- git_clone_repo(repo, ref, file.path(work_dir, "source"))
    }
    source_case <- resolve_source_case(row, source_root)
  }

  copy_dir(source_case, stage_dir)
  start_par_source <- find_final_par(row)
  if (!nzchar(start_par_source) || !file.exists(start_par_source)) {
    start_par_source <- latest_par(stage_dir)
  }
  if (!nzchar(start_par_source) || !file.exists(start_par_source)) {
    stop("Selected model does not contain a fitted .par file.", call. = FALSE)
  }
  compact_payloads <- file.path(compact_dir, c(
    "model_payload.rds", "profile_payload.rds", "info.rds", "model_info.rds"
  ))
  for (payload in compact_payloads[file.exists(compact_payloads)]) {
    file.copy(payload, file.path(stage_dir, basename(payload)), overwrite = TRUE, copy.date = TRUE)
  }
  start_name <- env("CHECK_START_PAR_NAME", "final.par")
  start_par <- file.path(stage_dir, start_name)
  file.copy(start_par_source, start_par, overwrite = TRUE, copy.date = TRUE)

  frq <- latest_file(case_files(stage_dir, "[.]frq$"))
  if (!nzchar(frq)) stop("Staged model case has no .frq file.", call. = FALSE)

  row_program_path <- as.character(row$mfcl_program_path %||% "")
  requested_program_path <- Sys.getenv("PROGRAM_PATH", unset = "")
  program_path <- if (nzchar(row_program_path) &&
      (!nzchar(requested_program_path) || identical(requested_program_path, "/home/mfcl/mfclo64"))) {
    row_program_path
  } else if (nzchar(requested_program_path)) {
    requested_program_path
  } else {
    "/home/mfcl/mfclo64"
  }

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  manifest <- data.frame(
    model_key = as.character(row$model_key %||% ""),
    selector = env("MODEL_SELECTOR", ""),
    candidate_type = as.character(row$candidate_type %||% ""),
    compact_dir = compact_dir,
    source_repo = env("MODEL_SOURCE_REPO", ""),
    source_ref = env("MODEL_SOURCE_REF", ""),
    source_root = source_root,
    source_case = source_case,
    stage_dir = normalize_loose(stage_dir),
    frq = basename(frq),
    start_par = basename(start_par),
    start_par_source = start_par_source,
    program_path = program_path,
    stringsAsFactors = FALSE
  )
  write.csv(manifest, file.path(output_dir, "check-input.csv"), row.names = FALSE)

  list(
    row = row,
    manifest = manifest,
    case_dir = normalize_loose(stage_dir),
    frq = normalize_loose(frq),
    start_par = normalize_loose(start_par),
    model_key = manifest$model_key[[1L]],
    program_path = manifest$program_path[[1L]]
  )
}

prepare_model_for_check <- function(input_root = default_input_root(),
                                    work_dir = env("WORK_DIR", "work"),
                                    output_dir = env("OUTPUT_DIR", "outputs")) {
  candidates <- discover_model_outputs(input_root)
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  if (nrow(candidates)) {
    write.csv(candidates, file.path(output_dir, "model-candidates.csv"), row.names = FALSE)
  }
  selected <- select_model_output(candidates, env("MODEL_SELECTOR", ""))
  stage_selected_model(selected, work_dir = work_dir, output_dir = output_dir)
}
