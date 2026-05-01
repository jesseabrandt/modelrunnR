# Implementation for stowing a file source. Stages the file into a
# DuckDB temp table via .mr_ingest_file_to_table(), hashes the staged
# table, and atomically promotes it to the canonical physical name (or
# drops it if a version with the same content already exists). Records
# source_uri / source_hash on the _mr_versions row.
#
# Called from:
#   - stow()'s mr_file dispatch branch (R/stow.R)
#   - ingest() (deprecation shim in R/ingest.R)
.mr_stow_file <- function(name, path, label = NA_character_) {
  .mr_validate_name(name, context = "stow")
  stopifnot(
    is.character(path),
    length(path) == 1L,
    nzchar(path)
  )
  if (!file.exists(path)) {
    stop(sprintf("stow(): file not found: %s", path), call. = FALSE)
  }

  con <- .mr_get_connection()

  staging <- paste0(
    "_mr_tmp_ingest_",
    paste(sample(c(0:9, letters), 10, replace = TRUE), collapse = "")
  )
  .mr_ingest_file_to_table(con, path, staging)
  staging_alive <- TRUE
  on.exit(
    if (staging_alive) try(.mr_drop_table(con, staging), silent = TRUE),
    add = TRUE
  )

  content_hash <- .mr_hash_duckdb_table(con, staging)
  physical_name <- .mr_physical_name(name, content_hash)
  src_hash      <- .mr_file_hash(path)
  src_uri       <- normalizePath(path, mustWork = TRUE)

  existing <- .mr_get_version_row(con, name, content_hash)
  now <- Sys.time()

  DBI::dbBegin(con)
  tryCatch({
    if (nrow(existing) == 0L) {
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
    staging_alive <- FALSE
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  .mr_record_write(name, content_hash)
  .mr_maybe_record_interactive_write(name, content_hash, label = label)
  .mr_maybe_warn_version_count(con, name)

  invisible(dplyr::tbl(con, physical_name))
}
