#' Persist a value to the modelrunnR artifact store
#'
#' Stores `value` under the logical name `name`. Writes are
#' content-addressed and non-destructive: a new version is created
#' whenever the content differs from the current latest, and all
#' previous versions remain queryable via [grab()] selectors.
#'
#' Inside a tracked [launch()], the write is recorded as an output
#' `{name, hash}` pair on the run row. Outside a launch, the write
#' still succeeds but is not logged against any step (Slice 6 will
#' add a synthetic interactive step id).
#'
#' Slice 3 of v0.1: accepts only data frames, which are stored as
#' DuckDB tables. Non-data-frame values will be supported as
#' artifacts in Slice 5.
#'
#' @param name A length-one character vector. Logical name for the
#'   value.
#' @param value A data frame.
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
      "stow(): only data frames are supported in this version; ",
      "artifacts (non-data-frame values) arrive in Slice 5.",
      call. = FALSE
    )
  }

  .mr_stow_table(name, value)
  invisible(value)
}

# Shared implementation for stowing a data frame. Called directly
# by stow() and by ingest() (which additionally updates source
# metadata on the just-written _mr_versions row). Returns the
# content hash invisibly so callers can key UPDATEs off of it
# without re-hashing.
.mr_stow_table <- function(name, value) {
  con  <- .mr_get_connection()
  hash <- .mr_hash_frame(con, value)
  physical_name <- .mr_physical_name(name, hash)

  existing <- .mr_get_version_row(con, name, hash)
  now <- Sys.time()

  if (nrow(existing) == 0L) {
    # New content: create the physical table and insert a _mr_versions row.
    .mr_table_write(con, physical_name, value, overwrite = TRUE)
    size_bytes <- as.numeric(object.size(value))
    DBI::dbExecute(
      con,
      "INSERT INTO _mr_versions
         (logical_name, content_hash, physical_name, kind,
          first_seen, last_seen, size_bytes)
       VALUES (?, ?, ?, 'table', ?, ?, ?)",
      params = list(name, hash, physical_name, now, now, size_bytes)
    )
  } else {
    # Same hash seen before — bump last_seen only.
    DBI::dbExecute(
      con,
      "UPDATE _mr_versions
         SET last_seen = ?
       WHERE logical_name = ? AND content_hash = ?",
      params = list(now, name, hash)
    )
  }

  # Refresh the convenience view so SQL clients can SELECT from the
  # logical name and get the latest version.
  .mr_refresh_latest_view(con, name)

  .mr_record_write(name, hash)
  invisible(hash)
}

## Internals ------------------------------------------------------------------

.mr_physical_name <- function(name, hash) {
  # Keep names human-readable in SHOW TABLES while staying short enough
  # to avoid any reasonable identifier limit. 16 hex chars of MD5 is
  # plenty of collision domain for a single logical name's history.
  sprintf("%s__%s", name, substr(hash, 1L, 16L))
}

.mr_get_version_row <- function(con, name, hash) {
  DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
    params = list(name, hash)
  )
}

.mr_refresh_latest_view <- function(con, name) {
  latest <- DBI::dbGetQuery(
    con,
    "SELECT physical_name FROM _mr_versions
      WHERE logical_name = ?
      ORDER BY first_seen DESC
      LIMIT 1",
    params = list(name)
  )
  if (nrow(latest) == 0L) return(invisible(NULL))
  sql <- sprintf(
    "CREATE OR REPLACE VIEW %s AS SELECT * FROM %s",
    .mr_quote_ident(name),
    .mr_quote_ident(latest$physical_name[1])
  )
  .mr_execute(con, sql)
  invisible(NULL)
}
