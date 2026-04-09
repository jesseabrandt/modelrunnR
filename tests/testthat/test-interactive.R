test_that("stow() outside launch writes a run row with a synthetic interactive step id", {
  new_test_db()
  stow("x", data.frame(n = 1:3))

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT step, status, outputs FROM _mr_runs")
  expect_equal(nrow(runs), 1L)
  expect_true(startsWith(runs$step[1], "<interactive:"))
  expect_equal(runs$status[1], "interactive")

  outs <- jsonlite::fromJSON(runs$outputs[1], simplifyVector = FALSE)
  names_produced <- vapply(outs, function(p) p$name, character(1))
  expect_equal(names_produced, "x")
})

test_that("grab() outside launch does not write a _mr_runs row", {
  new_test_db()
  stow("x", data.frame(n = 1:3))
  before <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  invisible(grab("x"))
  after <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  expect_equal(after, before)
})

test_that("launch emits a reproducibility warning when an input was last stowed interactively", {
  new_test_db()
  # Interactive write of 'x'.
  stow("x", data.frame(n = 1:3))
  # Script that grabs 'x'.
  s <- write_script(c(
    "v <- grab('x')",
    "stow('y', data.frame(n = nrow(v)))"
  ))
  expect_warning(
    launch(s),
    regexp = "grabs 'x'.*interactively.*not fully reproducible"
  )
})

test_that("launch does NOT warn when all inputs were produced by tracked runs", {
  new_test_db()
  # Write 'x' inside a tracked launch so its producer is a real script step.
  writer <- write_script("stow('x', data.frame(n = 1:3))")
  launch(writer)

  reader <- write_script(c(
    "v <- grab('x')",
    "stow('y', data.frame(n = nrow(v)))"
  ))
  expect_no_warning(launch(reader))
})

test_that("ingest() outside launch also produces an interactive run row", {
  new_test_db()
  dir <- withr::local_tempdir()
  csv <- file.path(dir, "d.csv")
  write.csv(data.frame(x = 1:3), csv, row.names = FALSE)

  ingest("d", csv)

  runs <- DBI::dbGetQuery(
    .mr_get_connection(),
    "SELECT step, status FROM _mr_runs ORDER BY started_at"
  )
  expect_equal(nrow(runs), 1L)
  expect_true(startsWith(runs$step[1], "<interactive:"))
  expect_equal(runs$status[1], "interactive")
})
