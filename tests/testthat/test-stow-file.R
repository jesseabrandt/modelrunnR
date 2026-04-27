# tests/testthat/test-stow-file.R

test_that("stow(mr_file(csv), name) round-trips identically to ingest()", {
  new_test_db()
  csv <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(x = 1:3, y = letters[1:3]), csv, row.names = FALSE)

  stow(mr_file(csv), "d")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_versions WHERE logical_name = 'd'"
  )
  expect_equal(nrow(row), 1L)
  expect_equal(normalizePath(row$source_uri[1]), normalizePath(csv))
  expect_true(nzchar(row$source_hash[1]))

  got <- grab("d") |> dplyr::collect()
  expect_equal(got$x, 1:3)
  expect_equal(as.character(got$y), letters[1:3])
})

test_that("stow(mr_file(path), name) errors when the file is missing", {
  new_test_db()
  expect_error(
    stow(mr_file("/no/such/file.csv"), "d"),
    "file not found"
  )
})

test_that("stow(mr_file(...)) is value-first; positional name second", {
  # Sanity check: this is the verb shape we promised in the spec.
  new_test_db()
  csv <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(n = 1:2), csv, row.names = FALSE)

  expect_silent(stow(mr_file(csv), "ds"))
  expect_equal(nrow(versions("ds")), 1L)
})

test_that("stow(mr_file(p)) without a name gives a clear missing-arg error, not the swap-detection misdirection", {
  # Regression: mr_file inherits from character, so the swap-detection
  # guard would otherwise treat the path as a name and suggest
  # `stow(<value>, "/path")` — which is meaningless. Excluding
  # mr_file from the guard lets the call fall through to a normal
  # missing-argument error.
  new_test_db()
  csv <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(x = 1), csv, row.names = FALSE)

  err <- tryCatch(stow(mr_file(csv)), error = function(e) conditionMessage(e))
  expect_false(grepl("value-first as of this version", err, fixed = TRUE),
               info = "swap-detection guard should not fire on mr_file values")
})
