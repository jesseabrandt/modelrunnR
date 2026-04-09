test_that("db_path() honors options(modelrunnR.db = ...)", {
  tmp <- withr::local_tempdir()
  custom <- file.path(tmp, "custom.duckdb")
  withr::local_options(list(modelrunnR.db = custom))
  expect_equal(db_path(), custom)
})
