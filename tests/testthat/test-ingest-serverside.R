test_that("ingest() does not route the frame through R", {
  new_test_db()
  tmp <- withr::local_tempfile(fileext = ".csv")
  write.csv(
    data.frame(x = 1:100, y = letters[rep(1:5, 20)]),
    tmp, row.names = FALSE
  )

  # Poison .mr_read_file so any regression that re-introduces the R
  # round-trip fails loudly. Use trace() so we're not permanently
  # shadowing the internal.
  called <- FALSE
  trace(
    ".mr_read_file",
    tracer = function() called <<- TRUE,
    print = FALSE,
    where = asNamespace("modelrunnR")
  )
  withr::defer(untrace(".mr_read_file", where = asNamespace("modelrunnR")))

  result <- suppressWarnings(ingest("csv_test", tmp))

  expect_false(called, info = "ingest() must not call .mr_read_file")
  expect_true(inherits(result, "tbl_lazy"))

  got_df <- dplyr::collect(grab("csv_test"))
  expect_equal(nrow(got_df), 100)
  expect_setequal(names(got_df), c("x", "y"))
})

test_that("ingest() records source_uri and source_hash", {
  new_test_db()
  tmp <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(a = 1:3), tmp, row.names = FALSE)

  suppressWarnings(ingest("src_meta", tmp))
  rows <- mr_versions_rows("src_meta")
  expect_equal(nrow(rows), 1L)
  expect_equal(normalizePath(rows$source_uri[1]), normalizePath(tmp))
  expect_false(is.na(rows$source_hash[1]))
})
