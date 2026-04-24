test_that("mr_run() rebind on Shape B filters grab() to that run", {
  new_test_db()
  run_lm <- launch({ stow(data.frame(m="lm", v=1), "metrics") }, label="lm")
  run_rf <- launch({ stow(data.frame(m="rf", v=2), "metrics") }, label="rf")

  e <- new.env(parent = globalenv())
  assign(".mr_rebind_test_env", e, envir = globalenv())
  on.exit(rm(".mr_rebind_test_env", envir = globalenv()), add = TRUE)

  launch({
    .mr_rebind_test_env$captured <- grab("metrics") |> dplyr::collect()
  }, label = "read", rebind = list(metrics = mr_run(run_lm$run_id)))

  captured <- e$captured
  expect_identical(nrow(captured), 1L)
  expect_identical(captured$m, "lm")
})

test_that("mr_hash() on a Shape B name with an unknown hash errors clearly", {
  new_test_db()
  launch({ stow(data.frame(m="lm"), "metrics") }, label = "lm")
  expect_error(
    launch({ grab("metrics") }, label = "r",
           rebind = list(metrics = mr_hash("abc"))),
    "does not match any chunk"
  )
})

test_that("mr_hash() on a Shape B name resolves to the chunk from versions()", {
  new_test_db()
  launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "lm")
  launch({ stow(data.frame(m = "rf", rmse = 0.4), "metrics") }, label = "rf")

  v <- versions("metrics")
  expect_equal(nrow(v), 2L)

  e <- new.env(parent = globalenv())
  assign(".mr_rebind_test_env", e, envir = globalenv())
  on.exit(rm(".mr_rebind_test_env", envir = globalenv()), add = TRUE)

  launch({
    .mr_rebind_test_env$captured <- grab("metrics") |> dplyr::collect()
  }, label = "read", rebind = list(metrics = mr_hash(v$content_hash[2])))  # older

  captured <- e$captured
  expect_equal(nrow(captured), 1L)
  expect_equal(captured$m, "lm")
})

test_that("mr_variant() rebind on Shape B filters to latest run with that label", {
  new_test_db()
  launch({ stow(data.frame(m="lm", v=1), "metrics") }, label="lm")
  launch({ stow(data.frame(m="rf", v=2), "metrics") }, label="rf")

  e <- new.env(parent = globalenv())
  assign(".mr_rebind_test_env", e, envir = globalenv())
  on.exit(rm(".mr_rebind_test_env", envir = globalenv()), add = TRUE)

  launch({
    .mr_rebind_test_env$captured <- grab("metrics") |> dplyr::collect()
  }, label = "read", rebind = list(metrics = mr_variant("rf")))

  captured <- e$captured
  expect_identical(nrow(captured), 1L)
  expect_identical(captured$m, "rf")
})

test_that("variants(name = ...) resolves Shape B names (backfill from Task 12)", {
  new_test_db()
  launch({ stow(data.frame(m="lm"), "metrics") }, label = "lm")
  launch({ stow(data.frame(m="rf"), "metrics") }, label = "rf")

  vs <- variants(name = "metrics")
  expect_true(all(c("lm", "rf") %in% vs$label))
})
