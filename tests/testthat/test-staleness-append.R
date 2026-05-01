# R-launch reads on append-shape (Shape B) names record the resolved
# chunk_hash on `_mr_runs.inputs`, mirroring SQL-launch semantics. This
# lets `.mr_check_inputs` detect upstream changes and re-fire the
# downstream consumer.
#
# Prior behavior (the bug fixed in TODO #20): R-launch grab() recorded
# NA_character_ for Shape B reads, so `.mr_check_inputs` skipped the
# comparison entirely and the consumer was always treated as fresh.

# Helper: run a producer that appends one row to "metrics", then a
# consumer that reads it. Returns the consumer run row.
.tsa_run_consumer <- function(script) {
  launch(script, label = "consumer")
}

test_that("R-launch grab() on a Shape B name records the chunk_hash on _mr_runs.inputs", {
  new_test_db()
  launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "producer")

  script <- tempfile(fileext = ".R")
  writeLines("x <- grab('metrics') |> dplyr::collect()", script)
  r <- launch(script, label = "consumer")

  inputs <- jsonlite::fromJSON(r$inputs[1], simplifyVector = FALSE)
  expect_identical(length(inputs), 1L)
  expect_identical(inputs[[1]]$name, "metrics")
  recorded <- inputs[[1]]$hash
  expect_false(is.null(recorded))
  expect_false(is.na(recorded))
  expect_true(nzchar(recorded))

  con <- .mr_get_connection()
  expected <- .mr_append_latest_chunk_hash(con, "metrics")
  expect_identical(recorded, expected)
})

test_that("a re-launched consumer goes stale when the upstream Shape B name appends a new chunk", {
  new_test_db()
  launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "producer_a")

  script <- tempfile(fileext = ".R")
  writeLines("x <- grab('metrics') |> dplyr::collect()", script)
  r1 <- launch(script, label = "consumer")
  expect_identical(r1$status, "success")

  # New upstream chunk -> consumer should re-fire, not skip_fresh.
  launch({ stow(data.frame(m = "rf", rmse = 0.4), "metrics") }, label = "producer_b")
  r2 <- launch(script, label = "consumer")
  expect_identical(r2$status, "success")
  expect_false(r2$run_id == r1$run_id)
})

test_that("a re-launched consumer skips fresh when the upstream Shape B name is unchanged", {
  new_test_db()
  launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "producer")

  script <- tempfile(fileext = ".R")
  writeLines("x <- grab('metrics') |> dplyr::collect()", script)
  r1 <- launch(script, label = "consumer")
  expect_identical(r1$status, "success")

  # No upstream change -> consumer should skip_fresh.
  r2 <- launch(script, label = "consumer")
  expect_identical(r2$status, "skipped_fresh")
})

test_that("from_run = run_id records that run's chunk_hash", {
  new_test_db()
  rp1 <- launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "p1")
  rp2 <- launch({ stow(data.frame(m = "rf", rmse = 0.4), "metrics") }, label = "p2")

  # Build a script that pins from_run = rp1$run_id, so the consumer
  # records the *first* producer's chunk_hash even though there's a
  # newer chunk available.
  script <- tempfile(fileext = ".R")
  writeLines(sprintf(
    "x <- grab('metrics', from_run = '%s') |> dplyr::collect()",
    rp1$run_id
  ), script)
  rc <- launch(script, label = "pinned_consumer")

  inputs <- jsonlite::fromJSON(rc$inputs[1], simplifyVector = FALSE)
  expect_identical(length(inputs), 1L)
  expect_identical(inputs[[1]]$name, "metrics")

  con <- .mr_get_connection()
  expected <- .mr_append_chunk_hash_for_run(con, "metrics", rp1$run_id)
  expect_false(is.na(expected))
  expect_identical(inputs[[1]]$hash, expected)
})

test_that("run = 'all' on a Shape B name records NA on _mr_runs.inputs", {
  new_test_db()
  launch({ stow(data.frame(m = "lm", rmse = 0.5), "metrics") }, label = "p1")
  launch({ stow(data.frame(m = "rf", rmse = 0.4), "metrics") }, label = "p2")

  script <- tempfile(fileext = ".R")
  writeLines("x <- grab('metrics', run = 'all') |> dplyr::collect()", script)
  rc <- launch(script, label = "all_consumer")

  inputs <- jsonlite::fromJSON(rc$inputs[1], simplifyVector = FALSE)
  expect_identical(length(inputs), 1L)
  expect_identical(inputs[[1]]$name, "metrics")
  # jsonlite round-trips NA_character_ as JSON null -> R NULL on read.
  expect_true(is.null(inputs[[1]]$hash) || is.na(inputs[[1]]$hash))
})
