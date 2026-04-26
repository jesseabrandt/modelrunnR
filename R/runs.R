#' List runs recorded in the modelrunnR store
#'
#' Returns the contents of `_mr_runs` as an eager tibble — one row per
#' run, all schema columns surfaced unmodified except that `code_body`
#' carries an [mr_code] class so that `dplyr::pull(code_body)` prints as
#' readable, syntax-highlighted code.
#'
#' This is the tidy backbone for inspecting the store. Filtering,
#' grouping, and counting are done with dplyr verbs on the returned
#' tibble — no new vocabulary. JSON-shaped columns (`inputs`, `outputs`,
#' `external_inputs`, `helpers`, `rebinds`, `attached_packages`) are
#' returned as plain character; parse on demand with
#' [jsonlite::fromJSON()].
#'
#' @return A tibble with all `_mr_runs` columns. `code_body` has class
#'   `c("mr_code", "character")`; all other columns are their natural
#'   types. Returns a zero-row tibble with the correct column types if
#'   the table exists but is empty. `duration_ms` (DuckDB `BIGINT`) is
#'   returned as `numeric` by default and as `integer64` when the
#'   `bit64` package is attached — the type depends on the active
#'   session, not on `runs()` itself.
#'
#' @seealso [versions()] for the produced-artifact view, [variants()]
#'   for the labeled-pipeline view, [launch_code()] to retrieve a
#'   run's source for inspection (with script-vs-snapshot
#'   reconciliation when the original step was a file).
#'
#' @examples
#' \dontrun{
#'   # What just happened?
#'   runs() |> tail(5)
#'
#'   # Read the code from one run
#'   runs() |>
#'     dplyr::filter(run_id == "run_20260425_143010_a4f9b2") |>
#'     dplyr::pull(code_body)
#' }
#' @export
runs <- function() {
  con <- .mr_get_connection()
  out <- DBI::dbReadTable(con, "_mr_runs")
  out <- tibble::as_tibble(out)
  out$code_body <- .mr_as_code(out$code_body)
  out
}
