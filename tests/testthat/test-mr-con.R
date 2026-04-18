test_that("mr_con() returns the live modelrunnR DuckDB connection", {
  new_test_db()
  con <- mr_con()
  expect_true(DBI::dbIsValid(con))
  expect_identical(con, .mr_get_connection())

  # Round-trip a query to prove it works as a plain DBI handle.
  result <- DBI::dbGetQuery(con, "SELECT 1 AS one")
  expect_equal(result$one, 1)
})
