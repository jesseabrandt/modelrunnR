## Parse-time errors fire before any DuckDB write.

mr_runs_count <- function() {
  con <- .mr_get_connection()
  DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n[[1]]
}

mr_versions_count <- function() {
  con <- .mr_get_connection()
  DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_versions")$n[[1]]
}

test_that("CREATE TABLE body errors before any _mr_runs / _mr_versions write", {
  new_test_db()
  before_runs <- mr_runs_count()
  before_versions <- mr_versions_count()
  expect_error(
    launch(mr_sql("-- @output: o\nCREATE TABLE foo AS SELECT 1")),
    "bare SELECT"
  )
  expect_equal(mr_runs_count(), before_runs)
  expect_equal(mr_versions_count(), before_versions)
})

test_that("multi-statement body errors before any DB write", {
  new_test_db()
  before <- mr_runs_count()
  expect_error(
    launch(mr_sql("-- @output: o\nSELECT 1; SELECT 2")),
    "exactly one statement"
  )
  expect_equal(mr_runs_count(), before)
})

test_that("unknown @key errors before any DB write", {
  new_test_db()
  before <- mr_runs_count()
  expect_error(
    launch(mr_sql("-- @output: o\n-- @bad: x\nSELECT 1")),
    "@bad"
  )
  expect_equal(mr_runs_count(), before)
})

test_that("inline SQL missing @output errors before any DB write", {
  new_test_db()
  before <- mr_runs_count()
  expect_error(launch(mr_sql("SELECT 1")), "@output")
  expect_equal(mr_runs_count(), before)
})

test_that("a stowed artifact blocks SQL view registration under the same name", {
  new_test_db()
  stow(list(a = 1), "out")     # artifact kind
  expect_error(
    launch(mr_sql("-- @output: out\nSELECT 1 AS x")),
    "already exists as an? artifact"
  )
})
