test_that("inline launch preserves pipes via srcref capture", {
  new_test_db()
  con <- modelrunnR:::.mr_get_connection()

  launch({
    x <- 1:3 |> sum() |> as.integer()
    stow(data.frame(v = x), "out", shape = "versioned")
  })

  body <- DBI::dbGetQuery(con,
    "SELECT code_body FROM _mr_runs ORDER BY started_at DESC LIMIT 1")$code_body[1]

  # Pipes preserved verbatim -- the previous deparse-based capture would
  # have rewritten them as nested calls (sum(...) instead of ... |> sum()).
  expect_match(body, "|>", fixed = TRUE)
  expect_match(body, "1:3 |> sum() |> as.integer()", fixed = TRUE)
})

test_that("identical inline bodies hash to the same step", {
  new_test_db()
  r1 <- launch({ stow(data.frame(n = 1), "out") }, label = "a")
  r2 <- launch({ stow(data.frame(n = 1), "out") }, label = "b")
  # Same body text, different labels -> same step (the inline:hash) but
  # different runs.
  expect_identical(r1$step, r2$step)
})
