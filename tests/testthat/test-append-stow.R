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
