test_that(".mr_migrate_append_chunks creates the lookup table with the expected schema", {
  withr::with_tempdir({
    new_test_db()
    con <- modelrunnR:::.mr_get_connection()
    info <- DBI::dbGetQuery(con, "DESCRIBE _mr_append_chunks")
    expect_setequal(
      info$column_name,
      c("logical_name", "run_id", "chunk_hash", "rows_appended", "started_at")
    )
    # Composite index for keyed lookups by (logical_name, run_id) is
    # in place; assert via duckdb_indexes() so a missed CREATE INDEX
    # surfaces as a regression rather than as a slow query.
    idx <- DBI::dbGetQuery(con,
      "SELECT index_name FROM duckdb_indexes()
        WHERE table_name = '_mr_append_chunks'")
    expect_true("_mr_append_chunks_logical_runid" %in% idx$index_name)
  })
})

test_that(".mr_migrate_append_chunks is idempotent — re-running keeps existing rows", {
  withr::with_tempdir({
    new_test_db()
    con <- modelrunnR:::.mr_get_connection()
    DBI::dbExecute(con,
      "INSERT INTO _mr_append_chunks (logical_name, run_id, chunk_hash,
         rows_appended, started_at)
       VALUES ('x', 'run_1', 'hash_a', 1, '2026-04-29 00:00:00')")
    # Re-run the migration (CREATE TABLE IF NOT EXISTS + CREATE INDEX
    # IF NOT EXISTS). Existing rows must survive.
    expect_silent(modelrunnR:::.mr_migrate_append_chunks(con))
    rows <- DBI::dbGetQuery(con,
      "SELECT chunk_hash FROM _mr_append_chunks")
    expect_equal(rows$chunk_hash, "hash_a")
  })
})
