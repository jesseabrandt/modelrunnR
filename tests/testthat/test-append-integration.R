test_that("_mr_runs.outputs records an append_table entry per Shape B stow", {
  new_test_db()
  run_row <- launch({
    stow(data.frame(model = "lm", rmse = 0.5), "metrics")
  }, label = "lm")

  outputs <- jsonlite::fromJSON(run_row$outputs[1], simplifyVector = FALSE)
  expect_identical(length(outputs), 1L)
  entry <- outputs[[1]]
  expect_identical(entry$kind,         "append_table")
  expect_identical(entry$logical_name, "metrics")
  expect_identical(entry$rows_appended, 1L)
  expect_true(nzchar(entry$chunk_hash))
})

test_that("_mr_runs.outputs for Shape A artifacts keeps the legacy {name, hash} pair shape", {
  new_test_db()
  run_row <- launch({
    stow(list(a = 1), "my_model")
  }, label = "a")

  outputs <- jsonlite::fromJSON(run_row$outputs[1], simplifyVector = FALSE)
  expect_identical(length(outputs), 1L)
  expect_identical(outputs[[1]]$name, "my_model")
  expect_true(nzchar(outputs[[1]]$hash))
})
