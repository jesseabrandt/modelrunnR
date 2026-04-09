#' Retrieve a value from the modelrunnR artifact store
#'
#' Returns whatever was most recently stowed under `name`. Inside a
#' tracked `launch()`, the read is recorded as an input to the running
#' step. Outside, the read is not logged.
#'
#' Slice 1 of v0.1: reads a DuckDB table by logical name. Non-table
#' artifacts (`is.data.frame(value) == FALSE`) are introduced in
#' Slice 5; selectors (`version`, `from_run`, `as_of`) and the
#' implicit-ingest `source` argument land in Slices 3 and 4.
#'
#' @param name A length-one character vector. Logical name that was
#'   previously `stow()`ed.
#'
#' @return A data frame (v0.1 Slice 1).
#' @export
grab <- function(name) {
  stopifnot(
    is.character(name),
    length(name) == 1L,
    nzchar(name)
  )

  con <- .mr_get_connection()
  if (!.mr_table_exists(con, name)) {
    stop(sprintf("grab(): no value stowed under '%s'", name), call. = FALSE)
  }

  .mr_record_read(name)
  .mr_table_read(con, name)
}
