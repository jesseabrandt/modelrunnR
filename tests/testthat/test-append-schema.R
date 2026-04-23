test_that("_mr_append_tables is created on connect with the expected columns", {
  new_test_db()
  con <- .mr_get_connection()
  expect_true(DBI::dbExistsTable(con, "_mr_append_tables"))
  info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_append_tables)")
  expect_setequal(
    info$name,
    c("logical_name", "physical_name", "schema_json",
      "first_seen", "last_seen", "row_count", "size_bytes")
  )
  pk <- info[info$pk == 1L, "name"]
  expect_identical(pk, "logical_name")
})

test_that("migration is idempotent", {
  new_test_db()
  con <- .mr_get_connection()
  # Force-run migrations a second time; must not error.
  expect_silent(.mr_migrate(con))
  expect_silent(.mr_migrate(con))
})
