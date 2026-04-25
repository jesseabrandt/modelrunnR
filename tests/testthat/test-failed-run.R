test_that("a script that errors still writes a run row with status = 'error'", {
  new_test_db()

  bad <- write_script(c(
    "stow(data.frame(x = 1), 'partial')",
    "stop('intentional')"
  ))

  expect_error(launch(bad), "intentional")

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT status, outputs, duration_ms FROM _mr_runs")
  expect_equal(nrow(runs), 1L)
  expect_equal(runs$status, "error")
  expect_false(is.na(runs$duration_ms[1]))

  # The stow that happened before the error must still be recorded as output.
  outs <- jsonlite::fromJSON(runs$outputs[1], simplifyVector = FALSE)
  # append-shape (data frame) entries use $logical_name instead of $name.
  out_names <- vapply(outs, function(p) {
    if (!is.null(p$name)) p$name else p$logical_name
  }, character(1))
  expect_equal(out_names, "partial")
})
