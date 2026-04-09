test_that("stow() errors cleanly on a non-data-frame value (artifacts land in Slice 5)", {
  new_test_db()

  expect_error(
    stow("thing", list(a = 1, b = 2)),
    regexp = "data frame"
  )
  expect_error(
    stow("thing", 1:10),
    regexp = "data frame"
  )
})
