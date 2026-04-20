## File-mode SQL launches: launch("path.sql").

write_sql <- function(text, name = "features.sql", envir = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = envir)
  path <- file.path(dir, name)
  writeLines(text, path)
  path
}

test_that("launch() on a .sql file registers a view and round-trips via grab()", {
  new_test_db()
  stow(data.frame(firm_id = 1:3, sales = c(10, 20, 30)), "panel_raw")

  sql_path <- write_sql(paste(
    "-- @inputs: panel_raw",
    "SELECT firm_id, sales * 2 AS sales_x2 FROM panel_raw",
    sep = "\n"
  ))
  run_row <- launch(sql_path)

  expect_equal(run_row$status, "success")
  expect_equal(nrow(run_row), 1L)

  rows <- mr_versions_rows("features")
  expect_equal(nrow(rows), 1L)
  expect_equal(rows$kind, "view")
  expect_true(!is.na(rows$source_sql))
  expect_match(rows$source_sql, "SELECT firm_id, sales \\* 2")

  out <- grab("features") |> dplyr::collect()
  expect_equal(nrow(out), 3L)
  expect_setequal(out$sales_x2, c(20, 40, 60))
})

test_that("@output overrides the filename-stem default", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")

  sql_path <- write_sql(paste(
    "-- @inputs: src",
    "-- @output: derived",
    "SELECT x + 1 AS y FROM src",
    sep = "\n"
  ), name = "ignored_name.sql")
  launch(sql_path)

  expect_equal(nrow(mr_versions_rows("derived")), 1L)
  expect_equal(nrow(mr_versions_rows("ignored_name")), 0L)
})

test_that("re-running an unchanged .sql file under the same label skips fresh", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  sql_path <- write_sql("-- @inputs: src\nSELECT * FROM src",
                        name = "features.sql")

  first  <- launch(sql_path, label = "v1")
  second <- launch(sql_path, label = "v1")
  expect_equal(first$status, "success")
  expect_equal(second$status, "skipped_fresh")
})

test_that("editing the SELECT body forces a new version and re-runs", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  sql_path <- write_sql("-- @inputs: src\nSELECT x FROM src",
                        name = "features.sql")
  launch(sql_path, label = "v1")
  v1_rows <- mr_versions_rows("features")

  writeLines("-- @inputs: src\nSELECT x + 1 AS x FROM src", sql_path)
  out <- launch(sql_path, label = "v1")
  expect_equal(out$status, "success")

  v2_rows <- mr_versions_rows("features")
  expect_equal(nrow(v2_rows), 2L)
  expect_false(identical(v1_rows$content_hash[1], v2_rows$content_hash[2]))
})

test_that("missing @inputs name errors before any DB write", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  sql_path <- write_sql("-- @inputs: not_there\nSELECT * FROM not_there",
                        name = "features.sql")
  before <- nrow(mr_versions_rows())
  expect_error(launch(sql_path),
               "@inputs references 'not_there' but no stowed value exists")
  expect_equal(nrow(mr_versions_rows()), before)
})

test_that("missing .sql file errors with the path", {
  new_test_db()
  expect_error(launch("/nope/does_not_exist.sql"), "not found")
})

test_that("CREATE TABLE body errors with bare-SELECT message", {
  new_test_db()
  sql_path <- write_sql("CREATE TABLE foo AS SELECT 1", name = "f.sql")
  expect_error(launch(sql_path), "bare SELECT")
})

test_that("multi-statement body errors", {
  new_test_db()
  sql_path <- write_sql("SELECT 1; SELECT 2", name = "f.sql")
  expect_error(launch(sql_path), "exactly one statement")
})

test_that("unknown @key errors", {
  new_test_db()
  sql_path <- write_sql("-- @foo: x\nSELECT 1", name = "f.sql")
  expect_error(launch(sql_path), "@foo")
})

test_that("a stowed table with the same name blocks a SQL view registration", {
  new_test_db()
  stow(data.frame(x = 1:3), "features")
  sql_path <- write_sql("SELECT 1 AS x", name = "features.sql")
  expect_error(launch(sql_path), "already exists as a table")
})
