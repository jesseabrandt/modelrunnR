test_that("prune() removes rows by older_than", {
  new_test_db()
  con <- .mr_get_connection()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")
  launch({ stow(data.frame(m = "rf"), "metrics") }, label = "rf")

  # Backdate the lm run.
  DBI::dbExecute(con,
    "UPDATE _mr_runs SET started_at = ? WHERE variant_label = 'lm'",
    params = list(as.POSIXct("2020-01-01", tz = "UTC")))

  # lm is variant-labeled — it's protected unless force = TRUE.
  # by='run' scopes to Shape B so we get a single-shape data frame back.
  pruned <- prune(by = "run", older_than = "30d", force = TRUE)
  expect_identical(pruned$rows_pruned, 1L)

  rows <- DBI::dbGetQuery(con, "SELECT * FROM metrics__append")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows[["_mr_variant_label"]], "rf")
})

test_that("prune() protects variant-labeled rows unless force = TRUE", {
  new_test_db()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")

  pruned <- suppressWarnings(prune("metrics", keep = 0))
  expect_identical(pruned$rows_pruned, 0L)
  pruned <- prune("metrics", keep = 0, force = TRUE)
  expect_identical(pruned$rows_pruned, 1L)
})

test_that("prune() keeps the registry row even when it drops all rows", {
  new_test_db()
  con <- .mr_get_connection()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")
  prune("metrics", keep = 0, force = TRUE)

  reg <- DBI::dbGetQuery(con,
    "SELECT * FROM _mr_append_tables WHERE logical_name = 'metrics'")
  expect_identical(nrow(reg), 1L)
  expect_equal(as.integer(reg$row_count), 0L)
})
