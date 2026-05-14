## L0 source-snapshot tests.
##
## Verifies that every launch path persists the bytes of its body
## (and any sourced helpers) into `_mr_code` / `_mr_code_helpers`,
## keyed by the same `code_hash` that the run row records.

write_bundle_local <- function(files, envir = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = envir)
  paths <- vapply(names(files), function(n) {
    p <- file.path(dir, n)
    writeLines(files[[n]], p)
    p
  }, character(1))
  as.list(setNames(paths, names(files)))
}

mr_code_row <- function(code_hash) {
  con <- .mr_get_connection()
  DBI::dbGetQuery(
    con,
    "SELECT code_hash, script_path, script_bytes, inline
       FROM _mr_code WHERE code_hash = ?",
    params = list(code_hash)
  )
}

mr_code_helper_rows <- function(code_hash) {
  con <- .mr_get_connection()
  DBI::dbGetQuery(
    con,
    "SELECT helper_path, helper_hash, helper_bytes
       FROM _mr_code_helpers WHERE code_hash = ?",
    params = list(code_hash)
  )
}

get_code_hash_for_run <- function(run_id) {
  con <- .mr_get_connection()
  DBI::dbGetQuery(
    con,
    "SELECT code_hash FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )$code_hash[[1L]]
}

test_that("_mr_code and _mr_code_helpers tables are created on connect", {
  new_test_db()
  con <- .mr_get_connection()
  tables <- DBI::dbListTables(con)
  expect_true("_mr_code" %in% tables)
  expect_true("_mr_code_helpers" %in% tables)
})

test_that("launching a file step writes a _mr_code row with the script bytes", {
  new_test_db()
  s <- write_script("stow(data.frame(n = 1), 'x')")
  run <- launch(s)

  ch <- get_code_hash_for_run(run$run_id)
  row <- mr_code_row(ch)
  expect_equal(nrow(row), 1L)
  expect_false(isTRUE(row$inline[[1L]]))
  expect_equal(row$script_path[[1L]], normalizePath(s, mustWork = TRUE))

  # Bytes round-trip to the same text we wrote (subject to the launch
  # path's line-ending normalization).
  bytes <- row$script_bytes[[1L]]
  expect_true(is.raw(bytes))
  expect_match(rawToChar(bytes), "stow\\(data\\.frame\\(n = 1\\), 'x'\\)")
})

test_that("inline launch writes a _mr_code row marked inline with NA path", {
  new_test_db()
  run <- launch({
    stow(data.frame(n = 1L), "x")
  })

  ch <- get_code_hash_for_run(run$run_id)
  row <- mr_code_row(ch)
  expect_equal(nrow(row), 1L)
  expect_true(isTRUE(row$inline[[1L]]))
  expect_true(is.na(row$script_path[[1L]]))
  expect_match(rawToChar(row$script_bytes[[1L]]), "stow")
})

test_that("sourced helpers are recorded in _mr_code_helpers with bytes", {
  new_test_db()
  b <- write_bundle_local(list(
    "helper.R" = "mkdf <- function() data.frame(n = 7L)",
    "step.R"   = ""
  ))
  writeLines(sprintf(
    "source('%s'); stow(mkdf(), 'out')", b$helper.R
  ), b$step.R)

  run <- launch(b$step.R)
  ch  <- get_code_hash_for_run(run$run_id)

  helpers <- mr_code_helper_rows(ch)
  expect_equal(nrow(helpers), 1L)
  expect_equal(
    helpers$helper_path[[1L]],
    normalizePath(b$helper.R, mustWork = TRUE)
  )
  expect_true(is.raw(helpers$helper_bytes[[1L]]))
  expect_match(rawToChar(helpers$helper_bytes[[1L]]), "mkdf")
})

test_that("identical code_hash across runs does not duplicate _mr_code rows", {
  new_test_db()
  s <- write_script("stow(data.frame(n = 1), 'x')")
  r1 <- launch(s)
  # Force re-run despite skip-on-fresh so we exercise a fresh snapshot
  # call against an already-persisted code_hash.
  r2 <- launch(s, force = TRUE)

  ch1 <- get_code_hash_for_run(r1$run_id)
  ch2 <- get_code_hash_for_run(r2$run_id)
  expect_identical(ch1, ch2)

  con <- .mr_get_connection()
  n   <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM _mr_code WHERE code_hash = ?",
    params = list(ch1)
  )$n[[1L]]
  expect_equal(n, 1L)
})

test_that(".mr_load_code round-trips script + helper bytes for a file launch", {
  new_test_db()
  b <- write_bundle_local(list(
    "helper.R" = "mkdf <- function() data.frame(n = 3L)",
    "step.R"   = ""
  ))
  writeLines(sprintf(
    "source('%s'); stow(mkdf(), 'out')", b$helper.R
  ), b$step.R)

  run <- launch(b$step.R)
  ch  <- get_code_hash_for_run(run$run_id)

  loaded <- .mr_load_code(.mr_get_connection(), ch)
  expect_false(is.null(loaded))
  expect_identical(loaded$code_hash, ch)
  expect_false(loaded$inline)
  expect_true(is.raw(loaded$script_bytes))
  expect_match(rawToChar(loaded$script_bytes), "stow\\(mkdf")
  expect_equal(length(loaded$helpers), 1L)
  expect_match(rawToChar(loaded$helpers[[1L]]$bytes), "mkdf")
})

test_that(".mr_load_code returns NULL for an unknown code_hash", {
  new_test_db()
  .mr_get_connection()
  expect_null(.mr_load_code(.mr_get_connection(), "no-such-hash"))
})

test_that("schema migration is idempotent across reconnects", {
  db <- new_test_db()
  con <- .mr_get_connection()
  # First connect already migrated. Run launches so the tables get
  # populated; then reset the cached connection and connect again.
  s <- write_script("stow(data.frame(n = 1), 'x')")
  run <- launch(s)
  expect_true("_mr_code" %in% DBI::dbListTables(con))

  .mr_reset_connection()
  con2 <- .mr_get_connection()
  # Migration on the second connect must not error and must not lose
  # the previously-recorded code row.
  ch <- get_code_hash_for_run(run$run_id)
  row <- DBI::dbGetQuery(
    con2,
    "SELECT COUNT(*) AS n FROM _mr_code WHERE code_hash = ?",
    params = list(ch)
  )
  expect_equal(row$n[[1L]], 1L)
})

test_that("SQL file launch writes a _mr_code row with the SQL bytes", {
  new_test_db()
  con <- .mr_get_connection()
  DBI::dbExecute(con, "CREATE TABLE src AS SELECT 1 AS x")

  dir <- withr::local_tempdir()
  sql_path <- file.path(dir, "step.sql")
  writeLines(c("-- @output: agg", "SELECT COUNT(*) AS n FROM src"), sql_path)

  run <- launch(sql_path)
  ch <- get_code_hash_for_run(run$run_id)
  row <- mr_code_row(ch)
  expect_equal(nrow(row), 1L)
  expect_false(isTRUE(row$inline[[1L]]))
  expect_match(rawToChar(row$script_bytes[[1L]]), "SELECT COUNT")
})
