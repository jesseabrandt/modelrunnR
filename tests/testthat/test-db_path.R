test_that("db_path() defaults to cwd/modelrunnR.duckdb when no option set", {
  tmp <- withr::local_tempdir()
  withr::local_dir(tmp)
  withr::local_options(list(modelrunnR.db = NULL))
  expect_equal(
    normalizePath(db_path(), mustWork = FALSE),
    normalizePath(file.path(tmp, "modelrunnR.duckdb"), mustWork = FALSE)
  )
})

test_that("db_path() honors options(modelrunnR.db = ...)", {
  tmp <- withr::local_tempdir()
  custom <- file.path(tmp, "custom.duckdb")
  withr::local_options(list(modelrunnR.db = custom))
  expect_equal(db_path(), custom)
})
