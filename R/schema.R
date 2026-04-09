## Schema migrations for the modelrunnR metadata tables.
##
## Called from `.mr_get_connection()` on every connect (idempotent).
## v0.1 Slice 1 introduces `_mr_runs` only; later slices layer on
## `_mr_versions`, `_mr_artifacts`, and additional columns.

.mr_migrate <- function(con) {
  .mr_migrate_runs(con)
  .mr_migrate_versions(con)
  invisible(NULL)
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
}
