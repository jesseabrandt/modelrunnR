## Tests for launch()'s default skip-on-fresh behavior (F8 fix).
##
## The launch()'d block evaluates in an env parented to globalenv(), so it
## doesn't see test-function locals. We pass the counter path via an
## env var and read it inside the block.

local_counter <- function(envir = parent.frame()) {
  path <- tempfile()
  writeLines("0", path)
  withr::local_envvar(list(MR_TEST_COUNTER = path), .local_envir = envir)
  path
}
counter_value <- function(path) as.integer(readLines(path))

test_that("default skip: second launch on a fresh step does not execute the block", {
  new_test_db()
  ctr <- local_counter()

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")
  expect_equal(counter_value(ctr), 1L)

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")
  expect_equal(counter_value(ctr), 1L)
})

test_that("skipped run writes a _mr_runs row with status 'skipped_fresh'", {
  new_test_db()
  launch({ stow(data.frame(n = 1), "out") }, label = "L")

  run <- launch({ stow(data.frame(n = 1), "out") }, label = "L")

  expect_equal(run$status, "skipped_fresh")
  expect_equal(run$duration_ms, 0L)
  expect_equal(run$inputs, "[]")
  expect_equal(run$outputs, "[]")
  con <- .mr_get_connection()
  n_skipped <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) AS n FROM _mr_runs WHERE status = 'skipped_fresh'"
  )$n
  expect_equal(n_skipped, 1L)
})

test_that("force = TRUE re-executes a fresh step", {
  new_test_db()
  ctr <- local_counter()

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")
  expect_equal(counter_value(ctr), 1L)

  run <- launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L", force = TRUE)

  expect_equal(counter_value(ctr), 2L)
  expect_equal(run$status, "success")
})

test_that("options(modelrunnR.skip_if_fresh = FALSE) restores advisory-only behavior", {
  new_test_db()
  withr::local_options(list(modelrunnR.skip_if_fresh = FALSE))
  ctr <- local_counter()

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")

  expect_equal(counter_value(ctr), 2L)
})

test_that("a stale step always runs regardless of skip setting", {
  new_test_db()
  ctr <- local_counter()

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")

  # Different expression bytes -> new <inline:hash> step -> never_run -> stale.
  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 10L), p)
    stow(data.frame(v = v + 10L), "out")
  }, label = "L")

  expect_equal(counter_value(ctr), 11L)
})

test_that("skip message mentions force = TRUE", {
  new_test_db()
  launch({ stow(data.frame(n = 1), "out") }, label = "L")

  msg <- paste(
    capture.output(
      launch({ stow(data.frame(n = 1), "out") }, label = "L"),
      type = "message"
    ),
    collapse = "\n"
  )
  expect_match(msg, "fresh")
  expect_match(msg, "skip")
  expect_match(msg, "force")
})

test_that("skipped run inherits variant_label from the prior run when caller omits label", {
  new_test_db()
  launch({ stow(data.frame(n = 1), "out") }, label = "L")

  run <- launch({ stow(data.frame(n = 1), "out") })
  expect_equal(run$status, "skipped_fresh")
  expect_equal(run$variant_label, "L")
})

test_that("force = TRUE on launch(mr_label(...)) re-executes the labeled pipeline", {
  new_test_db()
  ctr <- local_counter()

  launch({
    p <- Sys.getenv("MR_TEST_COUNTER")
    v <- as.integer(readLines(p))
    writeLines(as.character(v + 1L), p)
    stow(data.frame(v = v + 1L), "out")
  }, label = "L")
  expect_equal(counter_value(ctr), 1L)

  run_skipped <- launch(mr_label("L"))
  expect_equal(run_skipped$status, "skipped_fresh")
  expect_equal(counter_value(ctr), 1L)

  run_forced <- launch(mr_label("L"), force = TRUE)
  expect_equal(run_forced$status, "success")
  expect_equal(counter_value(ctr), 2L)
})
