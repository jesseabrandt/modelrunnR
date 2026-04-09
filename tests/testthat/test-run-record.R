test_that("run record captures observed inputs/outputs and success status", {
  new_test_db()

  # First launch: write two names.
  writer <- write_script(c(
    "stow('a', data.frame(x = 1))",
    "stow('b', data.frame(y = 2))"
  ))
  launch(writer)

  # Second launch: read one name, write another.
  rw <- write_script(c(
    "a <- grab('a')",
    "stow('c', data.frame(z = nrow(a)))"
  ))
  launch(rw)

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT step, inputs, outputs, status FROM _mr_runs ORDER BY started_at")

  expect_equal(nrow(runs), 2L)
  expect_equal(runs$status, c("success", "success"))

  # First run: no inputs, outputs = [a, b]
  r1_inputs  <- jsonlite::fromJSON(runs$inputs[1],  simplifyVector = TRUE)
  r1_outputs <- jsonlite::fromJSON(runs$outputs[1], simplifyVector = TRUE)
  expect_length(r1_inputs, 0L)
  expect_setequal(r1_outputs, c("a", "b"))

  # Second run: inputs = [a], outputs = [c]
  r2_inputs  <- jsonlite::fromJSON(runs$inputs[2],  simplifyVector = TRUE)
  r2_outputs <- jsonlite::fromJSON(runs$outputs[2], simplifyVector = TRUE)
  expect_equal(r2_inputs, "a")
  expect_equal(r2_outputs, "c")
})

test_that("run record stores a positive duration and a valid timestamp", {
  new_test_db()
  s <- write_script(c("stow('x', data.frame(n = 1))"))
  launch(s)

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT duration_ms, started_at FROM _mr_runs")
  expect_equal(nrow(runs), 1L)
  expect_true(!is.na(runs$duration_ms[1]))
  expect_gte(runs$duration_ms[1], 0)
  expect_true(inherits(runs$started_at[[1]], "POSIXct"))
})
