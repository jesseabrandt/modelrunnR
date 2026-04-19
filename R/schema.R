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
  # Slice 7 addition: content hash of the script + its helpers.
  .mr_add_column_if_missing(con, "_mr_runs", "code_hash", "TEXT")
  # Slice 8 addition: declared external inputs (files + env vars).
  .mr_add_column_if_missing(con, "_mr_runs", "external_inputs", "TEXT")
  # Slice 10 addition: the set of helper files (path + byte hash)
  # the run sourced. Needed so pre-run staleness checks can detect
  # a helper's content changing without having to source the script.
  .mr_add_column_if_missing(con, "_mr_runs", "helpers", "TEXT")
  # Swappability (Slice A): nullable label for tracked variants.
  .mr_add_column_if_missing(con, "_mr_runs", "variant_label", "TEXT")
  # Code body: the source executed by this run. Deparsed expression
  # for launch({ ... }) runs, captured file bytes for launch("f.R")
  # runs. Populated for every tracked run so a row is recoverable
  # even if its source file was later deleted.
  .mr_add_column_if_missing(con, "_mr_runs", "code_body", "TEXT")
  # DuckDB RNG seed captured when launch(..., duckdb_seed = x) was used.
  # Null when the caller didn't pass one.
  .mr_add_column_if_missing(con, "_mr_runs", "duckdb_seed", "DOUBLE")
  # Earlier draft named this column `inline_code` and only populated
  # it for inline launches. Carry the data forward and drop the old
  # column so `code_body` stays single-source-of-truth.
  info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_runs)")
  if ("inline_code" %in% info$name) {
    DBI::dbExecute(
      con,
      "UPDATE _mr_runs
          SET code_body = inline_code
        WHERE code_body IS NULL AND inline_code IS NOT NULL"
    )
    .mr_execute(con, "ALTER TABLE _mr_runs DROP COLUMN inline_code")
  }
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
  # Lazy-stow provenance: SQL text that produced an output, captured
  # via dbplyr::sql_render() at stow-time. Null for materialized-frame
  # stows and artifact stows.
  .mr_add_column_if_missing(con, "_mr_versions", "source_sql", "TEXT")
  # Belt-and-suspenders: the query-then-insert pattern in .mr_stow_*
  # already prevents duplicates in single-writer operation, but the
  # unique index makes the invariant enforced at the DB level against
  # concurrent writers or hand-edited databases.
  .mr_execute(
    con,
    "CREATE UNIQUE INDEX IF NOT EXISTS _mr_versions_logical_content_idx
       ON _mr_versions (logical_name, content_hash)"
  )
}

.mr_add_column_if_missing <- function(con, table, column, type) {
  # SQL column types cannot be bound as parameters, so `type` is
  # interpolated; constrain it to a small allowlist so a future caller
  # can't accidentally open an injection vector.
  valid_types <- c("TEXT", "BIGINT", "INTEGER", "DOUBLE",
                   "BLOB", "TIMESTAMP", "BOOLEAN")
  if (!(type %in% valid_types)) {
    stop(sprintf(
      ".mr_add_column_if_missing(): unsupported type '%s'. Allowed: %s",
      type, paste(valid_types, collapse = ", ")
    ), call. = FALSE)
  }
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
