## Schema migrations for the modelrunnR metadata tables.
##
## Called from `.mr_get_connection()` on every connect (idempotent).
## v0.1 Slice 1 introduces `_mr_runs` only; later slices layer on
## `_mr_versions`, `_mr_artifacts`, and additional columns.

#' Run all metadata-table migrations (idempotent)
#'
#' @param con DuckDB connection.
#' @return Invisibly NULL.
#' @noRd
.mr_migrate <- function(con) {
  .mr_migrate_runs(con)
  .mr_migrate_versions(con)
  .mr_migrate_artifacts(con)
  .mr_migrate_append_tables(con)
  .mr_migrate_append_chunks(con)
  .mr_migrate_code(con)
  invisible(NULL)
}

# L0 source snapshot: content-addressed code body bytes keyed by the
# `code_hash` already on `_mr_runs`. Separate `_mr_code_helpers` join
# table dedupes helpers shared across runs (one (code_hash, helper_path)
# row per unique helper contribution to a code_hash). Writes happen
# inside the launch's run-row transaction; idempotent on conflict.
#' Create the `_mr_code` and `_mr_code_helpers` tables and indexes
#'
#' @param con DuckDB connection.
#' @return Invisibly NULL.
#' @noRd
.mr_migrate_code <- function(con) {
  .mr_execute(
    con,
    "CREATE TABLE IF NOT EXISTS _mr_code (
       code_hash    TEXT PRIMARY KEY,
       script_path  TEXT,
       script_bytes BLOB,
       inline       BOOLEAN,
       recorded_at  TIMESTAMP
     )"
  )
  # No PRIMARY KEY on the helpers table: a single code_hash can reference
  # multiple distinct helper paths, and a helper_hash isn't unique either
  # (helpers shared across code_hashes legitimately repeat their hash).
  # Composite index on (code_hash) drives the join from _mr_code; the
  # (helper_hash) index supports future dedup queries.
  .mr_execute(
    con,
    "CREATE TABLE IF NOT EXISTS _mr_code_helpers (
       code_hash    TEXT NOT NULL,
       helper_path  TEXT NOT NULL,
       helper_hash  TEXT NOT NULL,
       helper_bytes BLOB
     )"
  )
  .mr_execute(
    con,
    "CREATE INDEX IF NOT EXISTS _mr_code_helpers_code_hash
       ON _mr_code_helpers (code_hash)"
  )
  .mr_execute(
    con,
    "CREATE INDEX IF NOT EXISTS _mr_code_helpers_helper_hash
       ON _mr_code_helpers (helper_hash)"
  )
  invisible(NULL)
}

#' Create the `_mr_artifacts` table and add the version storage column
#'
#' @param con DuckDB connection.
#' @return Result of the storage_location column migration (invisibly).
#' @noRd
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

#' Create `_mr_runs` and add all later-slice columns
#'
#' @param con DuckDB connection.
#' @return NULL (called for side effects); migrates the legacy inline_code column.
#' @noRd
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
  # Resolved-rebinds JSON (one object per rebound name) recording how
  # each name was selected: variant label, raw hash, run id, as_of,
  # or a literal R value preview. Populated by every run that goes
  # through .mr_resolve_rebinds(); empty array '[]' when no rebinds.
  .mr_add_column_if_missing(con, "_mr_runs", "rebinds", "TEXT")
  # Batch grouping id. One id per launch() call that fans out into a
  # batch (mr_binds() / mr_envelopes()); shared across all envelopes
  # in that batch. NULL for single-envelope launches -- they're
  # already uniquely identified by run_id.
  .mr_add_column_if_missing(con, "_mr_runs", "batch_id", "TEXT")
  # Session context (captured at launch start). Lets users compare
  # timing across machines / R versions / package sets without
  # round-tripping through sessionInfo() captures stowed by hand.
  # Free RAM is at-launch; total RAM and CPU count are host-stable.
  .mr_add_column_if_missing(con, "_mr_runs", "hostname",          "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "os",                "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "arch",              "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "r_version",         "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "n_cpu",             "INTEGER")
  .mr_add_column_if_missing(con, "_mr_runs", "total_ram_bytes",   "BIGINT")
  .mr_add_column_if_missing(con, "_mr_runs", "free_ram_bytes",    "BIGINT")
  # JSON array of {pkg, ver} for sessionInfo()$otherPkgs at launch
  # start (attached non-base packages). Variable-length so it stays
  # JSON; deduping into a session_info table is a future refactor.
  .mr_add_column_if_missing(con, "_mr_runs", "attached_packages", "TEXT")
  # Git context (captured at launch start, best-effort). git_sha is the
  # working tree's HEAD; git_branch the current branch (or "HEAD" when
  # detached); git_dirty is `git diff --shortstat HEAD` plus an
  # untracked-files count when applicable, or NA on a clean tree.
  # NA across all three when git is unavailable or the working dir
  # isn't a repo.
  .mr_add_column_if_missing(con, "_mr_runs", "git_sha",    "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "git_branch", "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "git_dirty",  "TEXT")
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

#' Create `_mr_versions`, add later-slice columns, and its unique index
#'
#' @param con DuckDB connection.
#' @return Result of the unique-index creation (invisibly).
#' @noRd
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
  # Bare-value rebind marker. TRUE for rows written through
  # launch(rebind = list(name = <bare value>)); FALSE for normal stows.
  # The latest-version resolver in grab() and .mr_refresh_latest_view()
  # filter these out so naked grab(name) keeps returning the real
  # upstream after a launch with a sample rebind. Existing pre-migration
  # rows default to FALSE — going forward the bug is fixed; retroactive
  # flagging is impossible because the rows are indistinguishable from
  # real stows once written.
  .mr_add_column_if_missing(con, "_mr_versions", "is_rebind", "BOOLEAN")
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

#' Create the `_mr_append_tables` registry table
#'
#' @param con DuckDB connection.
#' @return Invisibly NULL.
#' @noRd
.mr_migrate_append_tables <- function(con) {
  sql <- "
    CREATE TABLE IF NOT EXISTS _mr_append_tables (
      logical_name   TEXT PRIMARY KEY,
      physical_name  TEXT NOT NULL,
      schema_json    TEXT,
      first_seen     TIMESTAMP,
      last_seen      TIMESTAMP,
      row_count      BIGINT,
      size_bytes     BIGINT
    )
  "
  .mr_execute(con, sql)
  invisible(NULL)
}

# Per-chunk lookup table for append-shape data. One row per
# (logical_name, run_id, chunk_hash) tuple, populated at stow-commit
# time inside the same transaction as the row INSERT. Replaces the
# O(n_runs) JSON-scan over `_mr_runs.outputs` that earlier code paths
# used to resolve chunk_hash <-> run_id; also makes prune-cascades
# tractable (delete by run_id without re-walking every run row).
#' Create the `_mr_append_chunks` lookup table and its indexes
#'
#' @param con DuckDB connection.
#' @return Invisibly NULL.
#' @noRd
.mr_migrate_append_chunks <- function(con) {
  # No PRIMARY KEY: two distinct runs can legitimately produce the
  # same (logical_name, chunk_hash) when stowing deterministic
  # content, and a single run can stow the same chunk multiple times
  # within one launch. Use composite indexes for fast lookups by
  # (logical_name, chunk_hash) and (logical_name, run_id) without
  # the uniqueness constraint a PRIMARY KEY would impose.
  sql <- "
    CREATE TABLE IF NOT EXISTS _mr_append_chunks (
      logical_name   TEXT NOT NULL,
      run_id         TEXT NOT NULL,
      chunk_hash     TEXT NOT NULL,
      rows_appended  INTEGER,
      started_at     TIMESTAMP
    )
  "
  .mr_execute(con, sql)
  .mr_execute(
    con,
    "CREATE INDEX IF NOT EXISTS _mr_append_chunks_logical_hash
       ON _mr_append_chunks (logical_name, chunk_hash)"
  )
  .mr_execute(
    con,
    "CREATE INDEX IF NOT EXISTS _mr_append_chunks_logical_runid
       ON _mr_append_chunks (logical_name, run_id)"
  )
  invisible(NULL)
}

#' Add a column to a table if it does not already exist
#'
#' @param con DuckDB connection.
#' @param table Table name to alter.
#' @param column Column name to add.
#' @param type SQL column type (restricted to an allowlist).
#' @return Invisibly NULL.
#' @noRd
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
