#' Persist a value to the modelrunnR artifact store
#'
#' Stores `value` under the logical name `name`. Dispatches on type.
#' The two storage paths are:
#'
#' - **Append table** (for data frames and lazy DuckDB tbls) — writes
#'   into a single growing physical table per `name`, stamping every
#'   row with `_mr_run_id` and `_mr_variant_label`. Running 20 models
#'   that each `stow(<metrics>, "metrics")` produces one 20-row table,
#'   not 20 disjoint versions. Schema drift across runs reconciles
#'   losslessly: new columns are added, missing columns are NULL-filled,
#'   type conflicts coerce to TEXT (never drops a row).
#' - **Versioned artifact** (for any other R object) — serialized via
#'   `qs2`, hashed, and placed in `_mr_artifacts` as a BLOB row when
#'   serialized size is below `getOption("modelrunnR.blob_threshold")`
#'   (default 10 MB) or written to
#'   `<db_dir>/modelrunnR_artifacts/<name>__<hash>.qs2` otherwise. One
#'   version per distinct value; all previous versions stay queryable
#'   via [grab()] selectors.
#'
#' A logical name is tied to one shape on first write. Changing shape
#' later (e.g. `stow(df, "x")` then `stow(model, "x")`) errors.
#'
#' Inside a tracked [launch()], each write is recorded on the run row:
#' for append-table writes, as an `append_table` entry keyed by
#' `chunk_hash` (the hash of the rows this run contributed); for
#' artifacts, as a `{name, hash}` pair.
#'
#' Calling `stow()` outside any `launch()` is supported: it mints an
#' `<interactive:TS>` synthetic run row (matching the [ingest()]
#' convention) and stamps the written rows / metadata with that run_id.
#' Downstream launches that [grab()] an interactively-stowed value
#' receive the same reproducibility warning that applies to artifact
#' / ingest inputs.
#'
#' Note on serialization: `qs` is no longer maintained for recent R
#' versions, so modelrunnR uses its successor `qs2` (same fast/compact
#' format).
#'
#' @section Hashing contract:
#' For versioned artifacts, the hash is the serialized-bytes digest.
#' For append tables, the per-call `chunk_hash` is computed over the
#' rows this call contributed (order-independent for the eager frame
#' path; SQL-text-level for the lazy-tbl path — the two hash bases
#' differ, so round-tripping an identical frame through lazy vs eager
#' writes will show distinct chunks in [versions()]). Hashing for
#' DuckDB tables is type-sensitive: integer vs. double columns holding
#' the same values produce different hashes. Row names are not
#' persisted.
#'
#' @param value Any R value. First, so `df |> stow("name")` works.
#' @param name A length-one character vector. Logical name for the
#'   value.
#'
#' @return `value`, invisibly.
#' @export
stow <- function(value, name, shape = NULL) {
  if (missing(name) && is.character(value) && length(value) == 1L &&
      !inherits(value, "mr_file")) {
    stop(
      "stow() is value-first as of this version: stow(value, name). ",
      "Did you mean `stow(<value>, \"", value, "\")` ?",
      call. = FALSE
    )
  }
  # Also catch the name-first swap when both args are present:
  # stow("preds", df) — value is a scalar string, name is a data frame
  # (or any other non-character payload). Without this, .mr_validate_name
  # fails downstream with a less-useful "name must be a character"
  # message.
  if (!missing(name) && is.character(value) && length(value) == 1L &&
      !inherits(value, "mr_file") &&
      !is.character(name)) {
    stop(
      "stow() is value-first as of this version: stow(value, name). ",
      "Did you mean `stow(<value>, \"", value, "\")` ?",
      call. = FALSE
    )
  }
  .mr_validate_name(name, context = "stow")

  # Validate `shape`. Routing on `shape = "versioned"` is wired up in
  # Task 6; this task accepts the argument and rejects invalid usage
  # but otherwise has no behavioral effect.
  if (!is.null(shape)) {
    if (!is.character(shape) || length(shape) != 1L ||
        !shape %in% c("versioned", "append")) {
      stop(
        'stow(): shape must be NULL, "versioned", or "append".',
        call. = FALSE
      )
    }
    if (inherits(value, "mr_file")) {
      stop(
        "stow(): mr_file values are always versioned; drop the ",
        "shape argument.",
        call. = FALSE
      )
    }
    if (!is.data.frame(value) && !inherits(value, "tbl_lazy")) {
      stop(
        sprintf(
          "stow(): shape is only meaningful for data frames and lazy tbls; got %s.",
          paste(class(value), collapse = "/")
        ),
        call. = FALSE
      )
    }
  }

  if (inherits(value, "mr_file")) {
    .mr_guard_namespace(name, shape = "A")
    .mr_stow_file(name, unclass(value))
    return(invisible(value))
  }
  if (inherits(value, "tbl_lazy")) {
    .mr_guard_namespace(name, shape = "B")
    .mr_append_write_lazy(name, value)
  } else if (is.data.frame(value)) {
    .mr_guard_namespace(name, shape = "B")
    .mr_append_write_frame(name, value)
  } else {
    .mr_guard_namespace(name, shape = "A", new_kind = "artifact")
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
  if (.mr_has_nondefault_rownames(value)) {
    warning(
      "stow(): row names are not persisted by the DuckDB backend. ",
      "Convert to a column (e.g. with `tibble::rownames_to_column()`) ",
      "if you need them.",
      call. = FALSE
    )
  }
  # `.mr_hash_frame` creates a DuckDB temp table; DuckDB supports
  # transactional DDL so this is safe to run inside the wrapping
  # transaction below if we choose -- but we hash first so a bad value
  # fails fast before we ever dbBegin().
  hash <- .mr_hash_frame(con, value)
  physical_name <- .mr_physical_name(name, hash)

  existing <- .mr_get_version_row(con, name, hash)
  now <- Sys.time()

  # Atomic write: physical table + _mr_versions row + view refresh must
  # all succeed or all roll back. A crash between them would leave
  # orphaned physical tables or a stale view pointing at nothing.
  DBI::dbBegin(con)
  tryCatch({
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
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  .mr_record_write(name, hash)
  .mr_maybe_record_interactive_write(name, hash)
  .mr_maybe_warn_version_count(con, name)
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

    # For filesystem artifacts: write the file before starting the
    # transaction, so if the file write itself fails we haven't begun a
    # transaction. If the later INSERT rolls back, we delete the file in
    # the error handler so no orphan is left behind.
    file_written <- FALSE
    if (storage == "file") {
      dir.create(dirname(physical_name), recursive = TRUE, showWarnings = FALSE)
      writeBin(bytes, physical_name)
      file_written <- TRUE
    }

    DBI::dbBegin(con)
    tryCatch({
      if (storage == "blob") {
        DBI::dbExecute(
          con,
          "INSERT INTO _mr_artifacts (physical_name, payload) VALUES (?, ?)",
          params = list(physical_name, list(bytes))
        )
      }
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_versions
           (logical_name, content_hash, physical_name, kind,
            first_seen, last_seen, size_bytes, storage_location)
         VALUES (?, ?, ?, 'artifact', ?, ?, ?, ?)",
        params = list(name, hash, physical_name, now, now, size, storage)
      )
      DBI::dbCommit(con)
    }, error = function(e) {
      DBI::dbRollback(con)
      # Clean up the orphaned file artifact so crash-then-fix doesn't
      # leave untracked bytes on disk.
      if (file_written) try(file.remove(physical_name), silent = TRUE)
      stop(e)
    })
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
  .mr_maybe_warn_version_count(con, name)
  invisible(hash)
}

## Internals ------------------------------------------------------------------

.mr_maybe_warn_version_count <- function(con, name) {
  threshold <- getOption("modelrunnR.version_warn_threshold", 20L)
  count <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS c FROM _mr_versions WHERE logical_name = ?",
    params = list(name)
  )$c[1]
  if (count > threshold) {
    warning(sprintf(
      "'%s' has %d versions (threshold: %d). Consider running prune('%s', ...) to reclaim storage.",
      name, count, threshold, name
    ), call. = FALSE)
  }
  invisible(NULL)
}

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
  # Tables (kind='table') and SQL views (kind='view') both expose a
  # physical relation queryable via SELECT * FROM <physical>. Either
  # kind can back the latest-version convenience view at <logical>.
  latest <- DBI::dbGetQuery(
    con,
    "SELECT physical_name FROM _mr_versions
      WHERE logical_name = ? AND kind IN ('table', 'view')
      ORDER BY first_seen DESC
      LIMIT 1",
    params = list(name)
  )
  if (nrow(latest) == 0L) {
    # No versions left (prune-all). Drop the dangling view so direct
    # SQL against the logical name fails cleanly instead of pointing at
    # a dropped physical table.
    .mr_execute(
      con,
      sprintf("DROP VIEW IF EXISTS %s", .mr_quote_ident(name))
    )
    return(invisible(NULL))
  }
  sql <- sprintf(
    "CREATE OR REPLACE VIEW %s AS SELECT * FROM %s",
    .mr_quote_ident(name),
    .mr_quote_ident(latest$physical_name[1])
  )
  .mr_execute(con, sql)
  invisible(NULL)
}

