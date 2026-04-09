test_that("connection is opened lazily and cached across calls", {
  db <- new_test_db()

  # Nothing should have been created yet.
  expect_false(file.exists(db))

  con1 <- .mr_get_connection()
  expect_true(file.exists(db))
  expect_s4_class(con1, "DBIConnection")

  con2 <- .mr_get_connection()
  # Pointer equality via identical() on the S4 object.
  expect_true(identical(con1, con2))
})

test_that(".mr_reset_connection() drops the cache and re-opens fresh", {
  db <- new_test_db()
  con1 <- .mr_get_connection()
  .mr_reset_connection()
  con2 <- .mr_get_connection()
  expect_false(identical(con1, con2))
})
