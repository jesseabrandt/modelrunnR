test_that(".mr_resolve_relaunch_run_id() returns step + code_body + parsed expr for inline rows", {
  new_test_db()

  r <- launch({ x <- 1 + 1 })
  resolved <- modelrunnR:::.mr_resolve_relaunch_run_id(r$run_id)
  expect_match(resolved$step, "^<inline:")
  expect_true(nzchar(resolved$code_body))
  expect_true(inherits(resolved$expr, "expression"))
})

test_that(".mr_resolve_relaunch_run_id() returns step + code_body + NULL expr for file rows when file present", {
  new_test_db()

  writeLines("x <- 99", "fit.R")
  r <- launch("fit.R")
  resolved <- modelrunnR:::.mr_resolve_relaunch_run_id(r$run_id)
  expect_equal(normalizePath(resolved$step), normalizePath("fit.R"))
  expect_match(resolved$code_body, "x <- 99")
  expect_null(resolved$expr)
})

test_that(".mr_resolve_relaunch_run_id() falls back to stored snapshot when file is gone", {
  new_test_db()

  writeLines("x <- 99", "fit.R")
  r <- launch("fit.R")
  file.remove("fit.R")
  expect_message(
    resolved <- modelrunnR:::.mr_resolve_relaunch_run_id(r$run_id),
    "is gone from disk"
  )
  expect_match(resolved$code_body, "x <- 99")
  expect_true(inherits(resolved$expr, "expression"))
})

test_that(".mr_resolve_relaunch_run_id() errors clearly when no row matches", {
  new_test_db()

  expect_error(
    modelrunnR:::.mr_resolve_relaunch_run_id("run_does_not_exist"),
    "no run with run_id"
  )
})

test_that(".mr_resolve_relaunch_run_id() errors when row's step is a synthetic non-launch tag", {
  new_test_db()

  con <- modelrunnR:::.mr_get_connection()
  DBI::dbExecute(con, "INSERT INTO _mr_runs (step, run_id, status, code_body) VALUES (?, ?, ?, ?)",
                 params = list("<interactive:foo>", "run_synth", "interactive", "x <- 1"))
  expect_error(
    modelrunnR:::.mr_resolve_relaunch_run_id("run_synth"),
    "synthetic"
  )
})
