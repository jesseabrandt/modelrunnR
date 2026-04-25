test_that("mr_run() rebind on append-shape filters grab() to that run", {
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

test_that("mr_hash() on a append-shape name with an unknown hash errors clearly", {
  new_test_db()
  launch({ stow(data.frame(m="lm"), "metrics") }, label = "lm")
  expect_error(
    launch({ grab("metrics") }, label = "r",
           rebind = list(metrics = mr_hash("abc"))),
    "does not match any chunk"
  )
})

test_that("mr_hash() on a append-shape name resolves to the chunk from versions()", {
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

test_that("mr_variant() rebind on append-shape filters to latest run with that label", {
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

test_that("variants(name = ...) resolves append-shape names (backfill from Task 12)", {
  new_test_db()
  launch({ stow(data.frame(m="lm"), "metrics") }, label = "lm")
  launch({ stow(data.frame(m="rf"), "metrics") }, label = "rf")

  vs <- variants(name = "metrics")
  expect_true(all(c("lm", "rf") %in% vs$label))
})

test_that("mr_variant() rebind ignores runs that labeled the variant but did not write to name", {
  new_test_db()
  # "rf" labels a run that writes to `metrics` — the target.
  launch({ stow(data.frame(m = "rf_metrics"), "metrics") }, label = "rf")
  # "rf" also labels a later run that writes to `logs` — a different table.
  launch({ stow(data.frame(entry = "rf_log"), "logs") }, label = "rf")

  e <- new.env(parent = globalenv())
  assign(".mr_rebind_test_env", e, envir = globalenv())
  on.exit(rm(".mr_rebind_test_env", envir = globalenv()), add = TRUE)

  # mr_variant("rf") against `metrics` must resolve to the earlier run —
  # the one that actually produced metrics — not the latest rf-labeled run.
  launch({
    .mr_rebind_test_env$captured <- grab("metrics") |> dplyr::collect()
  }, label = "read", rebind = list(metrics = mr_variant("rf")))

  captured <- e$captured
  expect_equal(nrow(captured), 1L)
  expect_equal(captured$m, "rf_metrics")
})

test_that("mr_variant() rebind errors when no run both has label and wrote to name", {
  new_test_db()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")
  launch({ stow(data.frame(entry = "rf_log"), "logs") }, label = "rf")

  expect_error(
    launch({ grab("metrics") }, rebind = list(metrics = mr_variant("rf"))),
    "has not produced"
  )
})

test_that("mr_as_of() rebind resolves to latest producing run at or before ts, not latest system run", {
  new_test_db()
  con <- .mr_get_connection()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")
  # A later run that writes to a different table.
  launch({ stow(data.frame(x = 1), "other") })

  # Backdate the metrics run to a fixed time, leave the other-table run recent.
  DBI::dbExecute(con,
    "UPDATE _mr_runs SET started_at = ? WHERE variant_label = 'lm'",
    params = list(as.POSIXct("2025-01-01 00:00:00", tz = "UTC")))

  # as_of a time after the metrics run: should land on that metrics run,
  # not on the later write-to-other run that happens to have the latest
  # started_at system-wide.
  e <- new.env(parent = globalenv())
  assign(".mr_rebind_test_env", e, envir = globalenv())
  on.exit(rm(".mr_rebind_test_env", envir = globalenv()), add = TRUE)

  launch({
    .mr_rebind_test_env$captured <- grab("metrics") |> dplyr::collect()
  }, label = "read",
     rebind = list(metrics = mr_as_of(as.POSIXct("2026-01-01", tz = "UTC"))))

  expect_equal(nrow(e$captured), 1L)
  expect_equal(e$captured$m, "lm")
})
