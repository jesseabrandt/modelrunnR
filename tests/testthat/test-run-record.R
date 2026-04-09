## Helpers for parsing the JSON-encoded {name, hash} pair lists that
## Slice 3 introduced for _mr_runs.inputs/outputs.
parse_io <- function(json) {
  if (is.na(json) || !nzchar(json)) return(character())
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  vapply(parsed, function(p) p$name, character(1))
}

test_that("run record captures observed inputs/outputs and success status", {
  new_test_db()

  writer <- write_script(c(
    "stow('a', data.frame(x = 1))",
    "stow('b', data.frame(y = 2))"
  ))
  launch(writer)

  rw <- write_script(c(
    "a <- grab('a')",
    "stow('c', data.frame(z = nrow(a)))"
  ))
  launch(rw)

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT step, inputs, outputs, status FROM _mr_runs ORDER BY started_at")

  expect_equal(nrow(runs), 2L)
  expect_equal(runs$status, c("success", "success"))

  expect_length(parse_io(runs$inputs[1]), 0L)
  expect_setequal(parse_io(runs$outputs[1]), c("a", "b"))

  expect_equal(parse_io(runs$inputs[2]),  "a")
  expect_equal(parse_io(runs$outputs[2]), "c")
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
