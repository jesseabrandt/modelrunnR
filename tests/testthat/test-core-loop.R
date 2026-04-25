test_that("launch + stow round-trips a data frame to the next launch's grab (append-shape)", {
  new_test_db()

  writer <- write_script(c(
    "df <- data.frame(x = 1:3, y = letters[1:3], stringsAsFactors = FALSE)",
    "stow(df, 'out')"
  ))
  reader_path <- tempfile(fileext = ".rds")
  # Outside a launch grab('out') returns the full append table with run_id
  # and variant_label columns. Use run = 'all' to make intent explicit and
  # ensure the full data is available regardless of launch-context default.
  reader <- write_script(c(
    sprintf("got <- dplyr::collect(grab('out', run = 'all'))"),
    sprintf("saveRDS(got, %s)", deparse(reader_path))
  ))

  launch(writer)
  launch(reader)

  got <- readRDS(reader_path)
  expect_equal(nrow(got), 3L)
  # run='all' outside launch: user cols + run_id + variant_label
  expect_true(all(c("x", "y") %in% names(got)))
  expect_equal(got$x, 1:3)
  expect_equal(got$y, letters[1:3])
})

test_that("nested launch() errors instead of clobbering outer state", {
  new_test_db()

  inner <- write_script("stow(data.frame(a = 1), 'inner')")
  outer <- write_script(c(
    sprintf("launch(%s)", deparse(inner))
  ))

  expect_error(launch(outer), "nested launches are not supported")
})
