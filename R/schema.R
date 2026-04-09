## Schema migrations for the modelrunnR metadata tables.
##
## Called from `.mr_get_connection()` on every connect (idempotent).
## v0.1 Slice 1 introduces `_mr_runs` only; later slices layer on
## `_mr_versions`, `_mr_artifacts`, and additional columns.

.mr_migrate <- function(con) {
  .mr_migrate_runs(con)
  .mr_migrate_versions(con)
  .mr_migrate_artifacts(con)
  invisible(NULL)
}

.mr_migrate_artifacts <- function(con) {
  sql <- "
    CREATE TABLE IF NOT EXISTS _mr_artifacts (
      physical_name TEXT PRIMARY KEY,
      payload       BLOB
    )
  "
  .mr_execute(con, sql)
  # storage_location distinguishes blob-vs-filesystem for artifacts;
  # NULL for tables.
  .mr_add_column_if_missing(con, "_mr_versions", "storage_location", "TEXT")
}

.mr_migrate_runs <- function(con) {
  sql <- "
    CREATE TABLE IF NOT EXISTS _mr_runs (
      step         TEXT,
      run_id       TEXT,
      inputs       TEXT,
      outputs      TEXT,
      started_at   TIMESTAMP,
      duration_ms  BIGINT,
      status       TEXT
    )
  "
  .mr_execute(con, sql)
}

.mr_migrate_versions <- function(con) {
  sql <- "
    CREATE TABLE IF NOT EXISTS _mr_versions (
      logical_name   TEXT,
      content_hash   TEXT,
      physical_name  TEXT,
      kind           TEXT,
      first_seen     TIMESTAMP,
      last_seen      TIMESTAMP,
      size_bytes     BIGINT
    )
  "
  .mr_execute(con, sql)
  # Slice 4 additions: track the flat-file source a version was
  # ingested from so grab(source = path) can detect changes.
  .mr_add_column_if_missing(con, "_mr_versions", "source_uri",  "TEXT")
  .mr_add_column_if_missing(con, "_mr_versions", "source_hash", "TEXT")
}

.mr_add_column_if_missing <- function(con, table, column, type) {
  info <- DBI::dbGetQuery(
    con,
    sprintf("PRAGMA table_info(%s)", .mr_quote_ident(table))
  )
  if (!(column %in% info$name)) {
    .mr_execute(
      con,
      sprintf(
        "ALTER TABLE %s ADD COLUMN %s %s",
        .mr_quote_ident(table),
        .mr_quote_ident(column),
        type
      )
    )
  }
  invisible(NULL)
}
