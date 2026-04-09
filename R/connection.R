## Lazy, cached DuckDB connection keyed by the active `db_path()`.
##
## The connection lives in `.mr_state`. First caller opens it; subsequent
## callers in the same session reuse it. If `db_path()` changes between
## calls, the cached connection is closed and a fresh one opened.

.mr_get_connection <- function() {
  path <- db_path()
  cached_path <- .mr_state$db_path
  cached_con  <- .mr_state$connection

  if (!is.null(cached_con) && identical(cached_path, path) && DBI::dbIsValid(cached_con)) {
    return(cached_con)
  }

  # Path changed or cache invalid: close and reopen.
  if (!is.null(cached_con)) {
    .mr_disconnect(cached_con)
  }

  con <- .mr_connect(path)
  .mr_state$connection <- con
  .mr_state$db_path    <- path

  # Run migrations (idempotent).
  .mr_migrate(con)

  con
}

.mr_reset_connection <- function() {
  if (!is.null(.mr_state$connection)) {
    .mr_disconnect(.mr_state$connection)
  }
  .mr_state$connection <- NULL
  .mr_state$db_path    <- NULL
  invisible(NULL)
}
