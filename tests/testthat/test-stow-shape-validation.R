# tests/testthat/test-stow-shape-validation.R

test_that("stow() rejects unknown shape values", {
  new_test_db()
  df <- data.frame(x = 1)
  expect_error(
    stow(df, "d", shape = "garbage"),
    'shape must be NULL, "versioned", or "append"'
  )
})

test_that("stow() rejects shape on non-tabular values", {
  new_test_db()
  expect_error(
    stow(list(a = 1), "d", shape = "versioned"),
    "shape is only meaningful for data frames and lazy tbls"
  )
})

test_that("stow() rejects shape on mr_file values", {
  new_test_db()
  csv <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(x = 1), csv, row.names = FALSE)
  expect_error(
    stow(mr_file(csv), "d", shape = "versioned"),
    "mr_file values are always versioned"
  )
})

test_that("shape = 'append' on a frame is the explicit default (no error)", {
  new_test_db()
  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  on.exit(.mr_stop_recording(), add = TRUE)
  expect_silent(stow(data.frame(x = 1), "d", shape = "append"))
})
