#' Retrieve the code body for a previously-launched run
#'
#' Returns the code that produced `run_id`.
#'
#' For inline runs (`launch({ ... })`), the code body was deparsed and
#' stored on the run row at launch time, so there is only one source
#' to read from.
#'
#' For script runs (`launch("fit.R")`), there are two possible
#' sources: the script file as it currently sits on disk, and the
#' snapshot of the file bytes recorded on the run row at launch time.
#' By default, `launch_code()` reads the file on disk -- the current
#' file *is* the pipeline -- and falls back to the stored snapshot
#' (with a message) when the file has been removed. Pass
#' `from_db = TRUE` to force reading the stored snapshot even when
#' the file is still present: useful for auditing what a historical
#' run actually executed, independent of any later edits.
#'
#' @param run_id A run id as returned (invisibly) by [launch()] or as
#'   found on a `_mr_runs` row.
#' @param from_db If `TRUE`, return the code body stored on the run
#'   row at launch time, even for script-mode runs whose source file
#'   is still on disk. Defaults to `FALSE`.
#'
#' @return A length-one character vector containing the R code.
#' @export
launch_code <- function(run_id, from_db = FALSE) {
  stopifnot(
    is.character(run_id), length(run_id) == 1L, nzchar(run_id),
    is.logical(from_db), length(from_db) == 1L, !is.na(from_db)
  )
  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT step, code_body FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(row) == 0L) {
    stop(sprintf("launch_code(): no run with run_id '%s'", run_id),
         call. = FALSE)
  }
  step      <- row$step[1]
  code_body <- row$code_body[1]

  # Inline runs: only one source. The stored body is canonical.
  if (startsWith(step, "<inline:")) {
    if (is.na(code_body) || !nzchar(code_body)) {
      stop(sprintf(
        "launch_code(): run '%s' is inline but has no stored code (pre-migration row?).",
        run_id
      ), call. = FALSE)
    }
    return(code_body)
  }

  # Synthetic step ids for non-run activity (e.g. "<interactive:...>").
  if (startsWith(step, "<")) {
    stop(sprintf(
      "launch_code(): run '%s' has no stored code (step = '%s').",
      run_id, step
    ), call. = FALSE)
  }

  # Script runs. Prefer the stored snapshot when explicitly requested,
  # or when the source file is no longer on disk.
  if (from_db) {
    if (is.na(code_body) || !nzchar(code_body)) {
      stop(sprintf(
        "launch_code(): run '%s' has no stored snapshot (pre-migration row?).",
        run_id
      ), call. = FALSE)
    }
    return(code_body)
  }
  if (file.exists(step)) {
    return(paste(readLines(step, warn = FALSE), collapse = "\n"))
  }
  if (!is.na(code_body) && nzchar(code_body)) {
    message(sprintf(
      "launch_code(): script '%s' is no longer on disk; returning the stored snapshot from run '%s'. Pass from_db = TRUE to silence this message.",
      step, run_id
    ))
    return(code_body)
  }
  stop(sprintf(
    "launch_code(): script '%s' for run '%s' is gone from disk and no snapshot is stored.",
    step, run_id
  ), call. = FALSE)
}
