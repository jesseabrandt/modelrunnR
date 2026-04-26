test_that(".mr_recording_run_id returns NULL outside launch, run_id inside", {
  new_test_db()
  expect_null(.mr_recording_run_id())
  expect_null(.mr_recording_variant_label())

  .mr_start_recording(run_id = "run_fake_123", variant_label = "lm")
  expect_identical(.mr_recording_run_id(), "run_fake_123")
  expect_identical(.mr_recording_variant_label(), "lm")
  .mr_stop_recording()

  expect_null(.mr_recording_run_id())
  expect_null(.mr_recording_variant_label())
})

test_that(".mr_append_write_frame creates the physical table on first write", {
  new_test_db()
  con <- .mr_get_connection()
  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  on.exit(.mr_stop_recording(), add = TRUE)

  df <- data.frame(model = "lm", rmse = 0.5, r2 = 0.9, stringsAsFactors = FALSE)
  .mr_append_write_frame("metrics", df)

  expect_true(DBI::dbExistsTable(con, "metrics__append"))
  reg <- DBI::dbGetQuery(con, "SELECT * FROM _mr_append_tables WHERE logical_name = 'metrics'")
  expect_identical(nrow(reg), 1L)
  expect_identical(reg$physical_name, "metrics__append")
  expect_equal(as.integer(reg$row_count), 1L)

  rows <- DBI::dbGetQuery(con, "SELECT * FROM metrics__append")
  expect_identical(nrow(rows), 1L)
  expect_setequal(
    colnames(rows),
    c("model", "rmse", "r2", "_mr_run_id", "_mr_variant_label")
  )
  expect_identical(rows[["_mr_run_id"]], "run_1")
  expect_identical(rows[["_mr_variant_label"]], "lm")
})

test_that("second write appends under existing physical table", {
  new_test_db()
  con <- .mr_get_connection()

  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  .mr_append_write_frame("metrics",
    data.frame(model = "lm", rmse = 0.5, stringsAsFactors = FALSE))
  .mr_stop_recording()

  .mr_start_recording(run_id = "run_2", variant_label = "rf")
  .mr_append_write_frame("metrics",
    data.frame(model = "rf", rmse = 0.4, stringsAsFactors = FALSE))
  .mr_stop_recording()

  rows <- DBI::dbGetQuery(con,
    "SELECT * FROM metrics__append ORDER BY _mr_run_id")
  expect_identical(nrow(rows), 2L)
  expect_identical(rows[["_mr_run_id"]], c("run_1", "run_2"))
  expect_identical(rows[["_mr_variant_label"]], c("lm", "rf"))

  reg <- DBI::dbGetQuery(con,
    "SELECT row_count FROM _mr_append_tables WHERE logical_name = 'metrics'")
  expect_equal(as.integer(reg$row_count), 2L)
})

test_that("stowing a frame with reserved system columns errors pre-insert", {
  new_test_db()
  con <- .mr_get_connection()

  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  on.exit(.mr_stop_recording(), add = TRUE)

  bad <- data.frame(
    model      = "lm",
    `_mr_run_id` = "fake",
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
  expect_error(
    .mr_append_write_frame("metrics", bad),
    "'_mr_run_id' (is|are) reserved"
  )

  # No physical table created, no registry row written.
  expect_false(DBI::dbExistsTable(con, "metrics__append"))
  reg <- DBI::dbGetQuery(con,
    "SELECT * FROM _mr_append_tables WHERE logical_name = 'metrics'")
  expect_identical(nrow(reg), 0L)
})

test_that("stow(df, name) inside launch() routes to append-shape", {
  new_test_db()
  con <- .mr_get_connection()

  launch({
    stow(data.frame(model = "lm", rmse = 0.5, stringsAsFactors = FALSE),
         "metrics")
  }, label = "lm")

  launch({
    stow(data.frame(model = "rf", rmse = 0.4, stringsAsFactors = FALSE),
         "metrics")
  }, label = "rf")

  expect_true(DBI::dbExistsTable(con, "metrics__append"))
  rows <- DBI::dbGetQuery(con,
    "SELECT * FROM metrics__append ORDER BY _mr_variant_label")
  expect_identical(nrow(rows), 2L)
  expect_setequal(rows[["_mr_variant_label"]], c("lm", "rf"))

  # _mr_versions must NOT have metrics (versioned-shape) rows.
  versions <- DBI::dbGetQuery(con,
    "SELECT * FROM _mr_versions WHERE logical_name = 'metrics'")
  expect_identical(nrow(versions), 0L)
})

test_that("stow(obj, name) for non-tabular values still goes to versioned-shape", {
  new_test_db()
  con <- .mr_get_connection()
  launch({
    stow(list(a = 1, b = 2), "my_model")
  }, label = "x")

  versions <- DBI::dbGetQuery(con,
    "SELECT * FROM _mr_versions WHERE logical_name = 'my_model'")
  expect_identical(nrow(versions), 1L)
  expect_identical(versions$kind, "artifact")

  # And _mr_append_tables has nothing.
  reg <- DBI::dbGetQuery(con,
    "SELECT * FROM _mr_append_tables WHERE logical_name = 'my_model'")
  expect_identical(nrow(reg), 0L)
})

test_that("stow(tbl_lazy, name) materializes server-side into append-shape", {
  new_test_db()
  con <- .mr_get_connection()

  # Seed an ingested source to have something to dbplyr over.
  src <- tempfile(fileext = ".csv")
  write.csv(data.frame(model = c("lm","rf"), rmse = c(0.5, 0.4)),
            src, row.names = FALSE)
  suppressWarnings(ingest("src", src))

  launch({
    t <- grab("src")
    t |>
      dplyr::filter(rmse < 0.5) |>
      stow("filtered_metrics")
  }, label = "lm")

  expect_true(DBI::dbExistsTable(con, "filtered_metrics__append"))
  rows <- DBI::dbGetQuery(con, "SELECT * FROM filtered_metrics__append")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows$model, "rf")
  expect_false(is.na(rows[["_mr_run_id"]][1]))
  expect_identical(rows[["_mr_variant_label"]][1], "lm")
})

test_that("stow() warns when a data frame has non-default row names", {
  new_test_db()
  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  on.exit(.mr_stop_recording(), add = TRUE)

  df <- data.frame(x = 1:3)
  rownames(df) <- c("a", "b", "c")
  expect_warning(.mr_append_write_frame("metrics", df), "row names")
})
