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
#' Slice 3 of v0.1: tables only. Artifact support arrives in Slice 5.
#' The `source` argument for implicit ingest arrives in Slice 4.
#'
#' @param name A length-one character vector naming a logical value.
#' @param version Optional content hash (as returned by [versions()])
#'   to select a specific stored version.
#' @param from_run Optional run id (as returned by [launch()]'s
#'   invisibly-returned run row) to select the exact version produced
#'   by that run.
#' @param as_of Optional `POSIXct` timestamp; returns the version
#'   that was latest at that time.
#'
#' @return A data frame.
#' @export
grab <- function(name, version = NULL, from_run = NULL, as_of = NULL) {
  stopifnot(
    is.character(name),
    length(name) == 1L,
    nzchar(name)
  )
  con <- .mr_get_connection()

  resolved <- .mr_resolve_version(con, name, version, from_run, as_of)
  .mr_record_read(name, resolved$content_hash)
  .mr_table_read(con, resolved$physical_name)
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
    pairs <- jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE)
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
      stop(sprintf("grab(): version '%s' for '%s' not found (pruned?)", hash, name),
           call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  if (!is.null(as_of)) {
    if (!inherits(as_of, "POSIXct")) as_of <- as.POSIXct(as_of)
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
