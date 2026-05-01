test_that("stow() rejects shape = 'view' for non-lazy values", {
  new_test_db()
  expect_error(
    stow(data.frame(x = 1:3), "t", shape = "view"),
    "view.*lazy"
  )
  expect_error(
    stow(list(model = "fake"), "m", shape = "view"),
    "view.*lazy"
  )
})

test_that("stow() shape = 'view' raises 'not yet implemented' for lazy values (Task 4 placeholder)", {
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(year = 2014:2024, x = 1:11), "panel")
  panel <- grab("panel")

  expect_error(
    panel |> dplyr::filter(year <= 2020) |> stow("train", shape = "view"),
    "not yet implemented"
  )
})
