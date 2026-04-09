test_that("launch + stow round-trips a data frame to the next launch's grab", {
  new_test_db()

  writer <- write_script(c(
    "df <- data.frame(x = 1:3, y = letters[1:3], stringsAsFactors = FALSE)",
    "stow('out', df)"
  ))
  reader_path <- tempfile(fileext = ".rds")
  reader <- write_script(c(
    sprintf("got <- grab('out')"),
    sprintf("saveRDS(got, %s)", deparse(reader_path))
  ))

  launch(writer)
  launch(reader)

  got <- readRDS(reader_path)
  expect_equal(nrow(got), 3L)
  expect_equal(sort(names(got)), c("x", "y"))
  expect_equal(got$x, 1:3)
  expect_equal(got$y, letters[1:3])
})

test_that("stow outside launch writes, grab outside launch reads (no recording)", {
  new_test_db()

  df <- data.frame(a = c(1, 2, 3))
  stow("direct", df)

  got <- grab("direct")
  expect_equal(got$a, c(1, 2, 3))
})
