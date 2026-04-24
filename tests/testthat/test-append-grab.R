test_that("grab(name) inside launch() returns current-run rows only", {
  new_test_db()
  launch({ stow(data.frame(model = "lm", rmse = 0.5), "metrics") }, label = "lm")
  launch({ stow(data.frame(model = "rf", rmse = 0.4), "metrics") }, label = "rf")

  # Use a package-level env as a mutable mailbox visible to the inline eval
  # env (parent = globalenv). The <<- in the plan's template writes to
  # globalenv(), which is not the test frame, so we use an env object instead.
  .mr_grab_test_env <- new.env(parent = emptyenv())
  assign(".mr_grab_test_env", .mr_grab_test_env, envir = globalenv())
  on.exit(rm(".mr_grab_test_env", envir = globalenv()), add = TRUE)

  launch({
    .mr_grab_test_env$captured <- grab("metrics") |> dplyr::collect()
    stow(data.frame(model = "gbm", rmse = 0.3), "metrics")
  }, label = "gbm")

  # Inside the launch, grab("metrics") saw ONLY the rows stowed by
  # THIS run — before any stow() inside this block, that means zero rows.
  expect_identical(nrow(.mr_grab_test_env$captured), 0L)
})

test_that("grab(name) outside launch() returns all rows with run_id + variant_label", {
  new_test_db()
  launch({ stow(data.frame(model = "lm", rmse = 0.5), "metrics") }, label = "lm")
  launch({ stow(data.frame(model = "rf", rmse = 0.4), "metrics") }, label = "rf")

  all_rows <- grab("metrics") |> dplyr::collect()
  expect_identical(nrow(all_rows), 2L)
  expect_true("run_id" %in% colnames(all_rows))
  expect_true("variant_label" %in% colnames(all_rows))
  expect_false("_mr_run_id" %in% colnames(all_rows))
  expect_setequal(all_rows$variant_label, c("lm", "rf"))
})
