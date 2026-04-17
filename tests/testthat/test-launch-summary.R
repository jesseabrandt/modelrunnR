test_that("launch summary always includes (grabs, stows) counts", {
  new_test_db()

  s <- write_script(c(
    'stow(data.frame(x = 1), "a")',
    'stow(data.frame(x = 2), "b")'
  ))
  out <- capture.output(launch(s), type = "message") |> paste(collapse = "\n")
  expect_match(out, "\\(0 grabs")
  expect_match(out, "2 stows\\)")
})

test_that("launch summary appends a variant line when labeled explicitly", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  out <- capture.output(launch(s, label = "eta_0.01"), type = "message") |>
         paste(collapse = "\n")
  expect_match(out, "variant: eta_0.01")
})

test_that("launch summary notes inherited variant source", {
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'grab("model")',
    'stow(data.frame(a = 1), "out")'
  ))
  out <- capture.output(launch(cons), type = "message") |> paste(collapse = "\n")
  expect_match(out, "variant: eta_0.01")
  expect_match(out, "inherited from")
})
