test_that("new nullable columns exist after migration", {
  new_test_db()
  con <- .mr_get_connection()

  versions_info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_versions)")
  expect_true("source_sql" %in% versions_info$name)
  expect_equal(versions_info$type[versions_info$name == "source_sql"], "VARCHAR")

  runs_info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_runs)")
  expect_true("duckdb_seed" %in% runs_info$name)
  expect_equal(runs_info$type[runs_info$name == "duckdb_seed"], "DOUBLE")
})
