#' Load a flat file into the modelrunnR artifact store
#'
#' Reads a CSV or Parquet file via DuckDB and stows it under `name`,
#' recording the source file's URI and content hash in
#' `_mr_versions` so later [grab()] calls with `source = path` can
#' detect changes and re-ingest when needed.
#'
#' `ingest()` routes through the same storage path as [stow()], so
#' dedup, versioning, and view refresh all behave identically.
#'
#' @param name Logical name to store the loaded table under.
#' @param source Path to a `.csv`, `.tsv`, or `.parquet` file.
#'
#' @return The ingested data frame, invisibly.
#' @export
ingest <- function(name, source) {
  stopifnot(
    is.character(name),
    length(name) == 1L,
    nzchar(name),
    is.character(source),
    length(source) == 1L,
    nzchar(source)
  )
  if (!file.exists(source)) {
    stop(sprintf("ingest(): file not found: %s", source), call. = FALSE)
  }

  con <- .mr_get_connection()
  df  <- .mr_read_file(con, source)

  content_hash <- .mr_stow_table(name, df)
  src_hash     <- .mr_file_hash(source)
  src_uri      <- normalizePath(source, mustWork = TRUE)

  DBI::dbExecute(
    con,
    "UPDATE _mr_versions
        SET source_uri = ?, source_hash = ?
      WHERE logical_name = ? AND content_hash = ?",
    params = list(src_uri, src_hash, name, content_hash)
  )

  invisible(df)
}

# Latest recorded source_hash for a logical name, or NA if none exists.
.mr_latest_source_hash <- function(con, name) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT source_hash FROM _mr_versions
       WHERE logical_name = ? AND source_hash IS NOT NULL
       ORDER BY first_seen DESC
       LIMIT 1",
    params = list(name)
  )
  if (nrow(row) == 0L) NA_character_ else row$source_hash[1]
}
