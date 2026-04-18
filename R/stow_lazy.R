# Server-side stow of a dbplyr lazy tbl.
#
# Flow:
#   1. Verify the tbl is bound to the modelrunnR connection; otherwise
#      error clearly so the caller knows to collect() first.
#   2. Render the SQL via dbplyr::sql_render().
#   3. CREATE TABLE <staging> AS <sql>, hash it via .mr_hash_duckdb_table.
#   4. If the content hash already exists under this logical name:
#      drop staging, bump last_seen.
#   5. Else: rename staging -> canonical physical_name, INSERT the
#      _mr_versions row with source_sql populated, refresh the latest view.
#   6. Record the write on the current run row (same path as
#      .mr_stow_table).
.mr_stow_lazy <- function(name, value) {
  con <- .mr_get_connection()
  remote <- dbplyr::remote_con(value)
  if (!identical(remote, con)) {
    stop(
      "stow(): lazy tbl is bound to a different DBI connection; ",
      "call dplyr::collect() first and stow the materialized result.",
      call. = FALSE
    )
  }

  sql_text <- as.character(dbplyr::sql_render(value))

  staging <- paste0(
    "_mr_tmp_stow_",
    paste(sample(c(0:9, letters), 10, replace = TRUE), collapse = "")
  )
  .mr_execute(
    con,
    sprintf(
      "CREATE TABLE %s AS %s",
      .mr_quote_ident(staging), sql_text
    )
  )
  staging_alive <- TRUE
  on.exit(
    if (staging_alive) try(.mr_drop_table(con, staging), silent = TRUE),
    add = TRUE
  )

  content_hash <- .mr_hash_duckdb_table(con, staging)
  physical_name <- .mr_physical_name(name, content_hash)

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
            source_sql)
         VALUES (?, ?, ?, 'table', ?, ?, 0, NULL, ?)",
        params = list(name, content_hash, physical_name, now, now, sql_text)
      )
      .mr_refresh_latest_view(con, name)
    } else {
      DBI::dbExecute(
        con,
        "UPDATE _mr_versions
           SET last_seen = ?
         WHERE logical_name = ? AND content_hash = ?",
        params = list(now, name, content_hash)
      )
    }
    DBI::dbCommit(con)
    staging_alive <<- FALSE
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  .mr_record_write(name, content_hash)
  .mr_maybe_record_interactive_write(name, content_hash)
  .mr_maybe_warn_version_count(con, name)
  invisible(content_hash)
}
