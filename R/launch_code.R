#' Retrieve the code body for a previously-launched run
#'
#' Returns the code that produced `run_id`. For inline runs
#' (`launch({ ... })`), returns the deparsed expression body stored
#' on the run row. For script runs (`launch("fit.R")`), returns the
#' current contents of the script file, or errors if the file is no
#' longer on disk.
#'
#' The intent is: after a session ends, you can still recover the
#' code that produced any historical run -- either to re-execute it,
#' to inspect what an old variant actually did, or to diff two runs'
#' code bodies.
#'
#' @param run_id A run id as returned (invisibly) by [launch()] or
#'   as found on a `_mr_runs` row.
#'
#' @return A length-one character vector containing the R code.
#' @export
launch_code <- function(run_id) {
  stopifnot(is.character(run_id), length(run_id) == 1L, nzchar(run_id))
  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT step, inline_code FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(row) == 0L) {
    stop(sprintf("launch_code(): no run with run_id '%s'", run_id),
         call. = FALSE)
  }
  step        <- row$step[1]
  inline_code <- row$inline_code[1]

  if (!is.na(inline_code) && nzchar(inline_code)) {
    return(inline_code)
  }

  # Script mode: read the file from disk.
  if (startsWith(step, "<")) {
    # Interactive writes or pre-migration inline runs with no stored body.
    stop(sprintf(
      "launch_code(): run '%s' has no stored code (step = '%s').",
      run_id, step
    ), call. = FALSE)
  }
  if (!file.exists(step)) {
    stop(sprintf(
      "launch_code(): script '%s' for run '%s' is no longer on disk.",
      step, run_id
    ), call. = FALSE)
  }
  paste(readLines(step, warn = FALSE), collapse = "\n")
}
