# tests/testthat/test-ingest-deprecation.R

test_that("ingest() emits a deprecation warning and still works", {
  new_test_db()
  csv <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(x = 1:3), csv, row.names = FALSE)

  expect_warning(
    ingest("d", csv),
    "deprecated",
    ignore.case = TRUE
  )

  # And it actually wrote the data.
  got <- grab("d") |> dplyr::collect()
  expect_equal(got$x, 1:3)
})

test_that("ingest() points users at stow(mr_file(...))", {
  new_test_db()
  csv <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(x = 1), csv, row.names = FALSE)

  w <- tryCatch(
    {
      ingest("d", csv)
      NULL
    },
    warning = function(w) conditionMessage(w)
  )
  expect_match(w, "stow\\(mr_file\\(")
})
