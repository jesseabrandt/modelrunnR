#' Persist a value to the modelrunnR artifact store
#'
#' Stores `value` under the logical name `name`. Inside a tracked
#' `launch()`, the write is recorded as an output of the running step.
#' Outside, the write still succeeds but is not logged against any
#' step (Slice 6 will add a synthetic "interactive" step id).
#'
#' Slice 1 of v0.1: accepts only data frames, which are written as
#' DuckDB tables via an overwriting write. Non-data-frame values
#' will be supported as artifacts in Slice 5. Versioning
#' (non-destructive writes, content hashing) lands in Slice 3.
#'
#' @param name A length-one character vector. Logical name to write
#'   the value under.
#' @param value A data frame to store.
#'
#' @return `value`, invisibly.
#' @export
stow <- function(name, value) {
  stopifnot(
    is.character(name),
    length(name) == 1L,
    nzchar(name)
  )
  if (!is.data.frame(value)) {
    stop(
      "stow(): only data frames are supported in Slice 1 of v0.1; ",
      "artifacts (non-data-frame values) arrive in Slice 5.",
      call. = FALSE
    )
  }

  con <- .mr_get_connection()
  .mr_table_write(con, name, value, overwrite = TRUE)

  .mr_record_write(name)
  invisible(value)
}
