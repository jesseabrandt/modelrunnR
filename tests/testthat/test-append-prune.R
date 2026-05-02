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
  # by='run' scopes to append-shape so we get a single-shape data frame back.
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

test_that("prune(keep_latest=TRUE) keeps latest run per variant_label on Shape B", {
  new_test_db()
  con <- .mr_get_connection()

  # Two variants, two runs each. Backdate the first run of each so the
  # second run is unambiguously newer.
  launch({ stow(data.frame(v = "lm-old"), "metrics") }, label = "lm")
  DBI::dbExecute(con,
    "UPDATE _mr_runs SET started_at = ? WHERE variant_label = 'lm'",
    params = list(as.POSIXct("2020-01-01", tz = "UTC")))
  launch({ stow(data.frame(v = "lm-new"), "metrics") }, label = "lm")

  launch({ stow(data.frame(v = "rf-old"), "metrics") }, label = "rf")
  DBI::dbExecute(con,
    "UPDATE _mr_runs SET started_at = ? WHERE variant_label = 'rf'
      AND run_id NOT IN (SELECT run_id FROM _mr_runs ORDER BY started_at DESC LIMIT 3)",
    params = list(as.POSIXct("2020-01-01", tz = "UTC")))
  launch({ stow(data.frame(v = "rf-new"), "metrics") }, label = "rf")

  pruned <- prune("metrics", keep_latest = TRUE)
  # Two old chunks pruned (one per variant); two latest kept.
  expect_identical(pruned$rows_pruned, 2L)

  rows <- DBI::dbGetQuery(con, "SELECT v, _mr_variant_label AS lab FROM metrics__append ORDER BY lab")
  expect_identical(nrow(rows), 2L)
  expect_setequal(rows$v, c("lm-new", "rf-new"))
  expect_setequal(rows$lab, c("lm", "rf"))
})

test_that("prune(keep_latest=TRUE) groups unlabeled runs together on Shape B", {
  new_test_db()
  con <- .mr_get_connection()

  launch({ stow(data.frame(v = "a"), "metrics") })
  DBI::dbExecute(con,
    "UPDATE _mr_runs SET started_at = ? WHERE variant_label IS NULL",
    params = list(as.POSIXct("2020-01-01", tz = "UTC")))
  launch({ stow(data.frame(v = "b"), "metrics") })

  pruned <- prune("metrics", keep_latest = TRUE)
  expect_identical(pruned$rows_pruned, 1L)

  rows <- DBI::dbGetQuery(con, "SELECT v FROM metrics__append")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows$v, "b")
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
