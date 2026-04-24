test_that("incoming frame with extra columns triggers ALTER TABLE ADD + NULL backfill", {
  new_test_db()
  con <- .mr_get_connection()

  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  .mr_append_write_frame("metrics",
    data.frame(model = "lm", rmse = 0.5, stringsAsFactors = FALSE))
  .mr_stop_recording()

  .mr_start_recording(run_id = "run_2", variant_label = "rf")
  expect_warning(
    .mr_append_write_frame("metrics",
      data.frame(model = "rf", rmse = 0.4, mae = 0.3, r2 = 0.85,
                 stringsAsFactors = FALSE)),
    "extending schema"
  )
  .mr_stop_recording()

  rows <- DBI::dbGetQuery(con,
    "SELECT * FROM metrics__append ORDER BY _mr_run_id")
  expect_identical(nrow(rows), 2L)
  expect_true(all(c("model", "rmse", "mae", "r2") %in% colnames(rows)))
  # The prior run's row has NULL for the two new columns.
  expect_true(is.na(rows$mae[1]))
  expect_true(is.na(rows$r2[1]))
  expect_identical(rows$mae[2], 0.3)
  expect_identical(rows$r2[2],  0.85)

  # schema_json is updated to include mae + r2.
  reg <- DBI::dbGetQuery(con,
    "SELECT schema_json FROM _mr_append_tables WHERE logical_name = 'metrics'")
  schema <- jsonlite::fromJSON(reg$schema_json[1], simplifyVector = FALSE)
  expect_setequal(names(schema), c("model", "rmse", "mae", "r2"))
})
