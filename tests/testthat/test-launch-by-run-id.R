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

test_that("launch(mr_run(id)) re-executes inline pipelines", {
  new_test_db()

  r1 <- launch({ x <- 21 + 21; stow(x, "answer") })
  r2 <- launch(mr_run(r1$run_id), force = TRUE)
  expect_equal(r2$status, "success")
  expect_match(r2$step, "^<inline:")
  expect_equal(r2$step, r1$step)
  expect_false(r2$run_id == r1$run_id)
})

test_that("launch(mr_run(id)) re-sources the file for file pipelines", {
  new_test_db()

  writeLines("y <- 7; stow(y, 'seven')", "f.R")
  r1 <- launch("f.R")
  writeLines("y <- 8; stow(y, 'eight')", "f.R")
  r2 <- launch(mr_run(r1$run_id))
  expect_equal(r2$status, "success")
  con <- modelrunnR:::.mr_get_connection()
  latest <- DBI::dbGetQuery(con,
    "SELECT logical_name FROM _mr_versions WHERE logical_name = 'eight'")
  expect_true(nrow(latest) >= 1)
})

test_that("launch(mr_run(id)) errors when no row matches", {
  new_test_db()

  expect_error(launch(mr_run("run_no_such")), "no run with run_id")
})

test_that("launch(mr_run(id)) auto-inherits the source row's variant_label when caller passes none", {
  new_test_db()

  r1 <- launch({ z <- 1 }, label = "exp_a")
  r2 <- launch(mr_run(r1$run_id), force = TRUE)
  expect_equal(r2$variant_label, "exp_a")
})

test_that("launch(mr_run(id)) lets caller override variant_label", {
  new_test_db()

  r1 <- launch({ z <- 1 }, label = "exp_a")
  r2 <- launch(mr_run(r1$run_id), label = "exp_b")
  expect_equal(r2$variant_label, "exp_b")
})

test_that("launch(mr_run(id)) warns by default when source row's status isn't success", {
  new_test_db()

  r1 <- tryCatch(launch({ stop("boom") }), error = function(e) NULL)
  con <- modelrunnR:::.mr_get_connection()
  bad_id <- DBI::dbGetQuery(con, "SELECT run_id FROM _mr_runs WHERE status = 'error' LIMIT 1")$run_id[1]
  expect_warning(launch(mr_run(bad_id)), "status 'error'")
})

test_that("modelrunnR.relaunch_nonsuccess = 'silent' suppresses the warning", {
  withr::with_options(list(modelrunnR.relaunch_nonsuccess = "silent"), {
    new_test_db()

    tryCatch(launch({ stop("boom") }), error = function(e) NULL)
    con <- modelrunnR:::.mr_get_connection()
    bad_id <- DBI::dbGetQuery(con, "SELECT run_id FROM _mr_runs WHERE status = 'error' LIMIT 1")$run_id[1]
    expect_no_warning(launch(mr_run(bad_id)))
  })
})

test_that("modelrunnR.relaunch_nonsuccess = 'error' refuses with a clear message", {
  withr::with_options(list(modelrunnR.relaunch_nonsuccess = "error"), {
    new_test_db()

    tryCatch(launch({ stop("boom") }), error = function(e) NULL)
    con <- modelrunnR:::.mr_get_connection()
    bad_id <- DBI::dbGetQuery(con, "SELECT run_id FROM _mr_runs WHERE status = 'error' LIMIT 1")$run_id[1]
    expect_error(launch(mr_run(bad_id)), "modelrunnR.relaunch_nonsuccess")
  })
})
