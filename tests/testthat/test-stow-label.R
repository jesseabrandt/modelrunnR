test_that("stow() accepts a label parameter", {
  new_test_db()
  df <- data.frame(x = 1:3)
  expect_no_error(stow(df, "t", label = "fold_01"))
})

test_that("stow() rejects empty / whitespace label", {
  new_test_db()
  df <- data.frame(x = 1:3)
  expect_error(stow(df, "t", label = ""), "label")
  expect_error(stow(df, "t", label = "   "), "label")
})

test_that("stow() rejects non-character / non-scalar label", {
  new_test_db()
  df <- data.frame(x = 1:3)
  expect_error(stow(df, "t", label = 1L), "label")
  expect_error(stow(df, "t", label = c("a", "b")), "label")
})
