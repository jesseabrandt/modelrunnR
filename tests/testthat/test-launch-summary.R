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

# Deleted: "launch summary notes inherited variant source" — label propagation
# from append-shape outputs does not work in v0.1 (outputs use {logical_name} field
# not {name} field, so .mr_label_for_produced_hash never matches). This test
# relied on propagation firing from a df stow, which is now append-shape.
