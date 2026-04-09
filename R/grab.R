#' Retrieve a value from the modelrunnR artifact store
#'
#' Returns the value stowed under `name`. By default returns the
#' current latest version. Historical versions can be selected via
#' `version` (content hash), `from_run` (run id), or `as_of`
#' (timestamp), in that precedence order.
#'
#' Inside a tracked [launch()], the read is recorded as an input
#' `{name, hash}` pair on the run row. Outside a launch, the read
#' is not logged.
#'
#' When `source` is supplied, `grab()` behaves as an idempotent
#' read-or-ingest: if `name` does not exist yet, [ingest()] is called
#' under the hood. If `name` exists and the file's current content
#' hash differs from the latest stored `source_hash`, `ingest()`
#' is called again and a new version is created. If the file is
#' unchanged, the cached version is returned.
#'
#' @param name A length-one character vector naming a logical value.
#' @param version Optional content hash (as returned by [versions()])
#'   to select a specific stored version.
#' @param from_run Optional run id (as returned by [launch()]'s
#'   invisibly-returned run row) to select the exact version produced
#'   by that run.
#' @param as_of Optional `POSIXct` timestamp; returns the version
#'   that was latest at that time.
#' @param source Optional path to a CSV or Parquet file. Triggers an
#'   implicit [ingest()] when the file hash differs from (or is not
#'   yet present in) the stored source metadata.
#'
#' @section Security note:
#' Artifacts stored via [stow()] are deserialized on read with
#' `qs2::qs_deserialize()`. Opening a project produced by someone else
#' trusts the artifacts to the same extent as trusting that party's R
#' code: `qs2` does not have `readRDS`'s historical callback
#' arbitrary-code-execution surface, but it has not been independently
#' audited. Do not `grab()` from projects you would not `source()`.
#'
#' @return A data frame.
#' @export
grab <- function(name, version = NULL, from_run = NULL, as_of = NULL, source = NULL) {
  .mr_validate_name(name, context = "grab")
  con <- .mr_get_connection()

  if (!is.null(source)) {
    .mr_maybe_ingest(con, name, source)
  }

  # If a launch has rebound this name and the caller didn't provide
  # an explicit selector, resolve via the rebound content hash.
  if (is.null(version) && is.null(from_run) && is.null(as_of)) {
    pinned <- .mr_rebound_hash(name)
    if (!is.null(pinned)) version <- pinned
  }

  resolved <- .mr_resolve_version(con, name, version, from_run, as_of)
  .mr_record_read(name, resolved$content_hash)
  .mr_read_value(con, resolved)
}

# Given a _mr_versions row, return the stored value. Tables go through
# the DBI read path; artifacts are fetched from `_mr_artifacts` (for
# BLOB storage) or read from disk (for filesystem storage) and then
# deserialized via qs2.
.mr_read_value <- function(con, row) {
  if (identical(row$kind, "table")) {
    return(.mr_table_read(con, row$physical_name))
  }
  # artifact
  if (identical(row$storage_location, "blob")) {
    blob <- DBI::dbGetQuery(
      con,
      "SELECT payload FROM _mr_artifacts WHERE physical_name = ?",
      params = list(row$physical_name)
    )
    if (nrow(blob) == 0L) {
      stop(sprintf("grab(): artifact payload missing for '%s' (pruned?)",
                   row$physical_name), call. = FALSE)
    }
    bytes <- blob$payload[[1]]
    return(qs2::qs_deserialize(bytes))
  }
  # storage == "file"
  if (!file.exists(row$physical_name)) {
    stop(sprintf("grab(): artifact file missing: %s", row$physical_name), call. = FALSE)
  }
  bytes <- readBin(row$physical_name, what = "raw", n = file.info(row$physical_name)$size)
  qs2::qs_deserialize(bytes)
}

# Called by grab(source = ...). Ingests when either (a) the name has
# never been stored or (b) the current file's md5 differs from the
# latest stored source_hash. Silently no-ops otherwise.
.mr_maybe_ingest <- function(con, name, source) {
  existing <- DBI::dbGetQuery(
    con,
    "SELECT 1 FROM _mr_versions WHERE logical_name = ? LIMIT 1",
    params = list(name)
  )
  if (nrow(existing) == 0L) {
    ingest(name, source)
    return(invisible(NULL))
  }
  current <- .mr_file_hash(source)
  stored  <- .mr_latest_source_hash(con, name)
  if (is.na(stored) || !identical(current, stored)) {
    ingest(name, source)
  }
  invisible(NULL)
}

## Internals ------------------------------------------------------------------

# Resolve (logical_name + optional selector) to a _mr_versions row.
# Returns a single-row data frame or stops with a clear error.
.mr_resolve_version <- function(con, name, version, from_run, as_of) {
  if (!is.null(version)) {
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
      params = list(name, version)
    )
    if (nrow(row) == 0L) {
      stop(sprintf("grab(): version '%s' for '%s' not found", version, name),
           call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  if (!is.null(from_run)) {
    run <- DBI::dbGetQuery(
      con,
      "SELECT outputs FROM _mr_runs WHERE run_id = ?",
      params = list(from_run)
    )
    if (nrow(run) == 0L) {
      stop(sprintf("grab(): no run with run_id '%s'", from_run), call. = FALSE)
    }
    # Legacy/hand-edited rows can have NA or empty outputs; guard the
    # JSON parse rather than crash with an opaque jsonlite error.
    pairs <- if (is.na(run$outputs[1]) || !nzchar(run$outputs[1])) {
      list()
    } else {
      tryCatch(
        jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE),
        error = function(e) list()
      )
    }
    hash <- NULL
    for (p in pairs) {
      if (identical(p$name, name)) { hash <- p$hash; break }
    }
    if (is.null(hash)) {
      stop(sprintf("grab(): run '%s' did not produce '%s'", from_run, name),
           call. = FALSE)
    }
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
      params = list(name, hash)
    )
    if (nrow(row) == 0L) {
      stop(sprintf(
        "grab(): version '%s' for '%s' not found - the run's output has been pruned.",
        hash, name
      ), call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  if (!is.null(as_of)) {
    # DuckDB TIMESTAMP columns are timezone-naive. Parse string inputs
    # as UTC so `grab(as_of = "...")` is reproducible across machines
    # regardless of session `TZ`. Users who need a local-time reading
    # should pass an explicit POSIXct.
    if (!inherits(as_of, "POSIXct")) as_of <- as.POSIXct(as_of, tz = "UTC")
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions
         WHERE logical_name = ? AND first_seen <= ?
         ORDER BY first_seen DESC
         LIMIT 1",
      params = list(name, as_of)
    )
    if (nrow(row) == 0L) {
      stop(sprintf("grab(): no version of '%s' existed at %s", name, format(as_of)),
           call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  # Default: latest version for this name.
  row <- DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_versions
       WHERE logical_name = ?
       ORDER BY first_seen DESC
       LIMIT 1",
    params = list(name)
  )
  if (nrow(row) == 0L) {
    stop(sprintf("grab(): no value stowed under '%s'", name), call. = FALSE)
  }
  row[1, , drop = FALSE]
}
