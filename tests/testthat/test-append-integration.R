test_that("_mr_runs.outputs records an append_table entry per append-shape stow", {
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

test_that("_mr_runs.outputs for versioned-shape artifacts keeps the legacy {name, hash} pair shape", {
  new_test_db()
  run_row <- launch({
    stow(list(a = 1), "my_model")
  }, label = "a")

  outputs <- jsonlite::fromJSON(run_row$outputs[1], simplifyVector = FALSE)
  expect_identical(length(outputs), 1L)
  expect_identical(outputs[[1]]$name, "my_model")
  expect_true(nzchar(outputs[[1]]$hash))
})

test_that("per-stow transactions commit independently; mid-block throw preserves stows that completed", {
  new_test_db()
  con <- .mr_get_connection()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")

  expect_error(launch({
    stop("boom before any stow")
  }, label = "rf"), "boom")

  rows <- DBI::dbGetQuery(con, "SELECT * FROM metrics__append")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows[["_mr_variant_label"]], "lm")
})

test_that("skipped_fresh runs do not append rows", {
  new_test_db()
  con <- .mr_get_connection()
  launch({ stow(data.frame(m = "lm", v = 1), "metrics") }, label = "lm")
  # Re-run same block under same label — should be skipped_fresh, no new row.
  launch({ stow(data.frame(m = "lm", v = 1), "metrics") }, label = "lm")

  rows <- DBI::dbGetQuery(con, "SELECT * FROM metrics__append")
  expect_identical(nrow(rows), 1L)
})

test_that("append-shape inputs do not make downstream launches stale", {
  new_test_db()
  launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "producer")

  script <- tempfile(fileext = ".R")
  writeLines("x <- grab('metrics') |> dplyr::collect()", script)
  r1 <- launch(script, label = "consumer")
  r2 <- launch(script, label = "consumer")
  expect_identical(r2$status, "skipped_fresh")
})

test_that("label propagates across append-shape grab()", {
  new_test_db()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "experiment_x")

  script <- tempfile(fileext = ".R")
  writeLines("x <- grab('metrics') |> dplyr::collect()", script)
  r <- launch(script)
  expect_identical(r$variant_label, "experiment_x")
})
