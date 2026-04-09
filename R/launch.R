#' Launch an R script as a tracked modelrunnR step
#'
#' `launch()` is the tracked-execution entry point. It sources
#' `script_path` inside an instrumented context that watches for
#' `grab()` and `stow()` calls, measures wall-clock duration, and
#' writes a run record to `_mr_runs` whether the script succeeds
#' or errors.
#'
#' Slice 1 of v0.1: basic source + timing + run record. Later slices
#' add helper-file hashing, `code_hash`, `external_inputs`, `pin`,
#' and `data` arguments, and staleness diagnostics.
#'
#' The script is sourced in a fresh environment whose parent is
#' `globalenv()`. `grab` and `stow` are injected directly into the
#' script's environment so scripts can call them bare without a
#' preceding `library(modelrunnR)`.
#'
#' @param script_path Path to the R script to run.
#'
#' @return The run record (one row of `_mr_runs`), invisibly.
#' @export
launch <- function(script_path) {
  stopifnot(
    is.character(script_path),
    length(script_path) == 1L,
    nzchar(script_path)
  )
  if (!file.exists(script_path)) {
    stop(sprintf("launch(): script not found: %s", script_path), call. = FALSE)
  }

  # Normalize path so the `step` column is stable relative to resolution.
  step <- normalizePath(script_path, mustWork = TRUE)
  run_id     <- .mr_new_run_id()
  started_at <- Sys.time()
  start_secs <- as.numeric(started_at)

  # Ensure the connection + schema exist before we start timing user code.
  .mr_get_connection()

  .mr_start_recording()
  on.exit(
    {
      # If the caller Ctrl-C'd, we still want recording state cleaned up.
      if (.mr_is_recording()) .mr_stop_recording()
    },
    add = TRUE
  )

  status  <- "success"
  err_obj <- NULL
  tryCatch(
    .mr_source_script(step),
    error = function(e) {
      status  <<- "error"
      err_obj <<- e
    }
  )

  rec <- .mr_stop_recording()
  duration_ms <- as.integer(round((as.numeric(Sys.time()) - start_secs) * 1000))

  run_row <- .mr_write_run_row(
    step        = step,
    run_id      = run_id,
    inputs      = rec$inputs,
    outputs     = rec$outputs,
    started_at  = started_at,
    duration_ms = duration_ms,
    status      = status
  )

  .mr_print_timing_summary(step, duration_ms, status)

  if (!is.null(err_obj)) {
    stop(err_obj)
  }

  invisible(run_row)
}

## Internals ------------------------------------------------------------------

.mr_new_run_id <- function() {
  ts  <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
  suf <- paste(sample(c(0:9, letters[1:6]), 6, replace = TRUE), collapse = "")
  sprintf("run_%s_%s", gsub("[^0-9A-Za-z_]", "", ts), suf)
}

.mr_source_script <- function(path) {
  envir <- new.env(parent = globalenv())
  # Inject grab/stow so scripts can call them without library(modelrunnR).
  envir$grab <- grab
  envir$stow <- stow
  source(path, local = envir, echo = FALSE, keep.source = FALSE)
  invisible(NULL)
}

.mr_write_run_row <- function(step, run_id, inputs, outputs,
                              started_at, duration_ms, status) {
  con <- .mr_get_connection()
  row <- data.frame(
    step        = step,
    run_id      = run_id,
    inputs      = .mr_pairs_to_json(inputs),
    outputs     = .mr_pairs_to_json(outputs),
    started_at  = started_at,
    duration_ms = duration_ms,
    status      = status,
    stringsAsFactors = FALSE
  )
  DBI::dbAppendTable(con, "_mr_runs", row)
  row
}

# Serialize a list of list(name, hash) pairs to a JSON array of objects.
# `auto_unbox = TRUE` keeps scalar fields from getting wrapped in
# one-element arrays, which would make downstream parsers uglier.
.mr_pairs_to_json <- function(pairs) {
  if (length(pairs) == 0L) return("[]")
  jsonlite::toJSON(pairs, auto_unbox = TRUE)
}

.mr_print_timing_summary <- function(step, duration_ms, status) {
  message(sprintf(
    "modelrunnR: %s [%s] in %s ms",
    basename(step), status, format(duration_ms, big.mark = ",")
  ))
}
