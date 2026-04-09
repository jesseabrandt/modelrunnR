#' Persist a value to the modelrunnR artifact store
#'
#' Stores `value` under the logical name `name`. Writes are
#' content-addressed and non-destructive: a new version is created
#' whenever the content differs from the current latest, and all
#' previous versions remain queryable via [grab()] selectors.
#'
#' Dispatches on type:
#' - Data frames (including tibbles and data.tables) are stored as
#'   DuckDB tables via an idempotent physical-table + view pathway.
#' - Any other R object is stored as an **artifact**: serialized
#'   via `qs2`, hashed, and placed in `_mr_artifacts` as a BLOB row
#'   (when serialized size is below `getOption("modelrunnR.blob_threshold")`,
#'   default 10 MB) or written to
#'   `<db_dir>/modelrunnR_artifacts/<name>__<hash>.qs2` otherwise.
#'
#' Table and artifact names share a single logical namespace. A name
#' cannot refer to both — `stow("x", df)` after `stow("x", model)`
#' errors, and vice versa.
#'
#' Inside a tracked [launch()], the write is recorded as an output
#' `{name, hash}` pair on the run row.
#'
#' Note on serialization: the design commits to `qs`; `qs` is no
#' longer maintained for recent R versions, so modelrunnR uses its
#' successor `qs2`, which provides the same fast/compact format.
#'
#' @param name A length-one character vector. Logical name for the
#'   value.
#' @param value Any R value.
#'
#' @return `value`, invisibly.
#' @export
stow <- function(name, value) {
  stopifnot(
    is.character(name),
    length(name) == 1L,
    nzchar(name)
  )

  if (is.data.frame(value)) {
    .mr_guard_namespace(name, "table")
    .mr_stow_table(name, value)
  } else {
    .mr_guard_namespace(name, "artifact")
    .mr_stow_artifact(name, value)
  }
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
    .mr_table_write(con, physical_name, value, overwrite = TRUE)
    size_bytes <- as.numeric(object.size(value))
    DBI::dbExecute(
      con,
      "INSERT INTO _mr_versions
         (logical_name, content_hash, physical_name, kind,
          first_seen, last_seen, size_bytes, storage_location)
       VALUES (?, ?, ?, 'table', ?, ?, ?, NULL)",
      params = list(name, hash, physical_name, now, now, size_bytes)
    )
  } else {
    DBI::dbExecute(
      con,
      "UPDATE _mr_versions
         SET last_seen = ?
       WHERE logical_name = ? AND content_hash = ?",
      params = list(now, name, hash)
    )
  }

  .mr_refresh_latest_view(con, name)
  .mr_record_write(name, hash)
  .mr_maybe_record_interactive_write(name, hash)
  invisible(hash)
}

# Store a non-data-frame R object as an artifact. Blob for small
# payloads, filesystem for large ones, with the choice gated by
# modelrunnR.blob_threshold (default 10 MB).
.mr_stow_artifact <- function(name, value) {
  con   <- .mr_get_connection()
  bytes <- qs2::qs_serialize(value)
  hash  <- .mr_hash_bytes(bytes)
  size  <- length(bytes)

  threshold <- getOption("modelrunnR.blob_threshold", 10L * 1024L * 1024L)
  storage   <- if (size < threshold) "blob" else "file"

  existing <- .mr_get_version_row(con, name, hash)
  now <- Sys.time()

  if (nrow(existing) == 0L) {
    physical_name <- if (storage == "blob") {
      .mr_physical_name(name, hash)
    } else {
      .mr_artifact_file_path(name, hash)
    }

    if (storage == "blob") {
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_artifacts (physical_name, payload) VALUES (?, ?)",
        params = list(physical_name, list(bytes))
      )
    } else {
      dir.create(dirname(physical_name), recursive = TRUE, showWarnings = FALSE)
      writeBin(bytes, physical_name)
    }

    DBI::dbExecute(
      con,
      "INSERT INTO _mr_versions
         (logical_name, content_hash, physical_name, kind,
          first_seen, last_seen, size_bytes, storage_location)
       VALUES (?, ?, ?, 'artifact', ?, ?, ?, ?)",
      params = list(name, hash, physical_name, now, now, size, storage)
    )
  } else {
    DBI::dbExecute(
      con,
      "UPDATE _mr_versions
         SET last_seen = ?
       WHERE logical_name = ? AND content_hash = ?",
      params = list(now, name, hash)
    )
  }

  .mr_record_write(name, hash)
  .mr_maybe_record_interactive_write(name, hash)
  invisible(hash)
}

## Internals ------------------------------------------------------------------

.mr_physical_name <- function(name, hash) {
  sprintf("%s__%s", name, substr(hash, 1L, 16L))
}

.mr_artifact_file_path <- function(name, hash) {
  # Artifacts live next to the DuckDB file so they travel with it.
  dir <- file.path(dirname(db_path()), "modelrunnR_artifacts")
  file.path(dir, sprintf("%s__%s.qs2", name, substr(hash, 1L, 16L)))
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
      WHERE logical_name = ? AND kind = 'table'
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

# Error if `name` already exists under a different kind (e.g. an
# attempt to overwrite a table with an artifact).
.mr_guard_namespace <- function(name, new_kind) {
  con <- .mr_get_connection()
  existing_kinds <- DBI::dbGetQuery(
    con,
    "SELECT DISTINCT kind FROM _mr_versions WHERE logical_name = ?",
    params = list(name)
  )$kind
  if (length(existing_kinds) > 0L && !all(existing_kinds == new_kind)) {
    stop(sprintf(
      "stow(): '%s' already exists as a %s; stowing it as a %s would collide. Use a different name.",
      name, existing_kinds[1], new_kind
    ), call. = FALSE)
  }
  invisible(NULL)
}
