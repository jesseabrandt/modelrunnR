## Unit tests for the SQL header parser used by .sql / mr_sql() launches.

test_that("plain SELECT body parses with empty inputs and NULL output", {
  res <- .mr_parse_sql_header("SELECT 1 AS x")
  expect_identical(res$inputs, character())
  expect_null(res$output)
  expect_identical(res$body, "SELECT 1 AS x")
})

test_that("@inputs single name parses", {
  res <- .mr_parse_sql_header("-- @inputs: panel_raw\nSELECT * FROM panel_raw")
  expect_identical(res$inputs, "panel_raw")
  expect_null(res$output)
  expect_identical(res$body, "SELECT * FROM panel_raw")
})

test_that("@inputs multiple names parse comma-separated", {
  res <- .mr_parse_sql_header(
    "-- @inputs: a, b, c\nSELECT * FROM a JOIN b USING(k) JOIN c USING(k)"
  )
  expect_identical(res$inputs, c("a", "b", "c"))
})

test_that("@output overrides the filename-stem default", {
  res <- .mr_parse_sql_header(
    "-- @inputs: x\n-- @output: features\nSELECT * FROM x"
  )
  expect_identical(res$output, "features")
})

test_that("blank lines and non-@ comments are skipped", {
  res <- .mr_parse_sql_header(
    paste(
      "-- some descriptive note",
      "",
      "-- @inputs: x",
      "-- another note",
      "SELECT * FROM x",
      sep = "\n"
    )
  )
  expect_identical(res$inputs, "x")
})

test_that("WITH ... SELECT parses as a valid bare body", {
  body <- "WITH cte AS (SELECT 1 AS k) SELECT * FROM cte"
  res <- .mr_parse_sql_header(body)
  expect_identical(res$body, body)
})

test_that("WITH with multiple CTEs and nested parens parses", {
  body <- "WITH a AS (SELECT 1), b AS (SELECT (SELECT 2) AS k FROM a) SELECT * FROM b"
  res <- .mr_parse_sql_header(body)
  expect_identical(res$body, body)
})

test_that("WITH ... SELECT with FROM-side subquery parses", {
  # Earlier draft tracked the LAST closing paren in the body and would
  # mistake the FROM-side subquery's `)` for the end of the CTE list.
  body <- "WITH a AS (SELECT 1) SELECT * FROM (SELECT 2 AS k) sub"
  res <- .mr_parse_sql_header(body)
  expect_identical(res$body, body)
})

test_that("block-comment with embedded semicolon is NOT a false multi-statement", {
  # DuckDB itself parses `/* ... */` as a comment, so an embedded `;`
  # cannot escape a CREATE OR REPLACE VIEW wrapper. The parser must
  # not falsely reject this body as multi-statement.
  res <- .mr_parse_sql_header("SELECT 1 /* ; harmless */")
  expect_match(res$body, "^SELECT 1")
})

test_that("trailing semicolon is stripped", {
  res <- .mr_parse_sql_header("SELECT 1;")
  expect_identical(res$body, "SELECT 1")
})

test_that("CREATE TABLE body errors with bare-SELECT message", {
  expect_error(
    .mr_parse_sql_header("CREATE TABLE foo AS SELECT 1"),
    "bare SELECT"
  )
})

test_that("INSERT body errors", {
  expect_error(.mr_parse_sql_header("INSERT INTO x VALUES (1)"), "bare SELECT")
})

test_that("WITH ... INSERT terminal errors", {
  expect_error(
    .mr_parse_sql_header(
      "WITH cte AS (SELECT 1) INSERT INTO foo SELECT * FROM cte"
    ),
    "bare SELECT"
  )
})

test_that("multi-statement body errors", {
  expect_error(
    .mr_parse_sql_header("SELECT 1; SELECT 2"),
    "exactly one statement"
  )
})

test_that("unknown @key errors", {
  expect_error(
    .mr_parse_sql_header("-- @foo: x\nSELECT 1"),
    "@foo"
  )
})

test_that("malformed @inputs (no colon) errors", {
  expect_error(
    .mr_parse_sql_header("-- @inputs panel_raw\nSELECT 1"),
    "malformed"
  )
})

test_that("@output with multiple names errors", {
  expect_error(
    .mr_parse_sql_header("-- @output: a, b\nSELECT 1"),
    "single name"
  )
})

test_that("repeating @inputs errors", {
  expect_error(
    .mr_parse_sql_header("-- @inputs: a\n-- @inputs: b\nSELECT * FROM a, b"),
    "repeating"
  )
})

test_that("empty body errors", {
  expect_error(.mr_parse_sql_header("-- @inputs: x\n"), "empty")
})

test_that("mr_sql() constructor returns a classed list", {
  s <- mr_sql("SELECT 1")
  expect_s3_class(s, "mr_ref_sql")
  expect_s3_class(s, "mr_ref")
  expect_identical(s$kind, "sql")
  expect_identical(s$body, "SELECT 1")
})

test_that("mr_sql() rejects non-character body", {
  expect_error(mr_sql(123), "character")
  expect_error(mr_sql(NA_character_), "NA")
  expect_error(mr_sql(c("a", "b")), "length-1")
})
