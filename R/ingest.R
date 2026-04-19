#' Load a flat file into the modelrunnR artifact store
#'
#' Loads a CSV or Parquet file directly into DuckDB using DuckDB's
#' native `read_csv_auto()` / `read_parquet()` — the file bytes never
#' pass through R memory. The resulting table is stored under `name`,
#' recording the source file's URI and content hash in
#' `_mr_versions` so later [grab()] calls with `source = path` can
#' detect changes and re-ingest when needed.
#'
#' `ingest()` routes through the same storage path as [stow()], so
#' dedup, versioning, and view refresh all behave identically.
#'
#' @section Hashing contract:
#' Column types inferred by DuckDB's `read_csv_auto()` may differ from
#' the types of a frame you might `stow()` directly. Because the
#' content hash is type-sensitive (see [stow()]'s hashing contract), a
#' CSV round-trip through `ingest()` can produce a new version even
#' when the values are numerically identical.
#'
#' @param name Logical name to store the loaded table under.
#' @param source Path to a `.csv`, `.tsv`, or `.parquet` file.
#'
#' @return A `dbplyr` lazy `tbl` over the ingested table, invisibly.
#'   Users typically don't use the return value directly — they call
#'   [grab()] to read the stored data by name.
#' @export
ingest <- function(name, source) {
  .mr_validate_name(name, context = "ingest")
  stopifnot(
    is.character(source),
    length(source) == 1L,
    nzchar(source)
  )
  if (!file.exists(source)) {
    stop(sprintf("ingest(): file not found: %s", source), call. = FALSE)
  }

  con <- .mr_get_connection()

  # Stage into a temp table name, hash it, then rename to the canonical
  # physical_name(name, hash) if this is a new version (or drop it if
  # the content already exists under this logical_name).
  staging <- paste0(
    "_mr_tmp_ingest_",
    paste(sample(c(0:9, letters), 10, replace = TRUE), collapse = "")
  )
  .mr_ingest_file_to_table(con, source, staging)
  staging_alive <- TRUE
  on.exit(
    if (staging_alive) try(.mr_drop_table(con, staging), silent = TRUE),
    add = TRUE
  )

  content_hash <- .mr_hash_duckdb_table(con, staging)
  physical_name <- .mr_physical_name(name, content_hash)
  src_hash      <- .mr_file_hash(source)
  src_uri       <- normalizePath(source, mustWork = TRUE)

  existing <- .mr_get_version_row(con, name, content_hash)
  now <- Sys.time()

  DBI::dbBegin(con)
  tryCatch({
    if (nrow(existing) == 0L) {
      # Promote staging to the canonical physical_name.
      .mr_execute(
        con,
        sprintf(
          "ALTER TABLE %s RENAME TO %s",
          .mr_quote_ident(staging), .mr_quote_ident(physical_name)
        )
      )
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_versions
           (logical_name, content_hash, physical_name, kind,
            first_seen, last_seen, size_bytes, storage_location,
            source_uri, source_hash)
         VALUES (?, ?, ?, 'table', ?, ?, ?, NULL, ?, ?)",
        params = list(name, content_hash, physical_name, now, now,
                      0, src_uri, src_hash)
      )
      .mr_refresh_latest_view(con, name)
    } else {
      DBI::dbExecute(
        con,
        "UPDATE _mr_versions
           SET last_seen = ?, source_uri = ?, source_hash = ?
         WHERE logical_name = ? AND content_hash = ?",
        params = list(now, src_uri, src_hash, name, content_hash)
      )
    }
    DBI::dbCommit(con)
    staging_alive <<- FALSE  # renamed away; no drop on exit
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  .mr_record_write(name, content_hash)
  .mr_maybe_record_interactive_write(name, content_hash)
  .mr_maybe_warn_version_count(con, name)

  invisible(dplyr::tbl(con, physical_name))
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
