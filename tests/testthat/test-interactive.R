test_that("stow() of a non-df artifact outside launch writes a synthetic interactive step id", {
  new_test_db()
  stow(list(n = 1:3), "x_artifact")

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT step, status, outputs FROM _mr_runs")
  expect_equal(nrow(runs), 1L)
  expect_true(startsWith(runs$step[1], "<interactive:"))
  expect_equal(runs$status[1], "interactive")

  outs <- jsonlite::fromJSON(runs$outputs[1], simplifyVector = FALSE)
  names_produced <- vapply(outs, function(p) p$name, character(1))
  expect_equal(names_produced, "x_artifact")
})

test_that("stow() of a data frame outside launch writes an interactive run row and stamps rows", {
  new_test_db()
  df <- data.frame(model = "lm", rmse = 0.5, stringsAsFactors = FALSE)
  stow(df, "metrics")

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(
    con, "SELECT step, status, run_id, outputs FROM _mr_runs"
  )
  expect_equal(nrow(runs), 1L)
  expect_true(startsWith(runs$step[1], "<interactive:"))
  expect_equal(runs$status[1], "interactive")

  # The interactive run's id should be the stamp on the appended rows.
  rows <- DBI::dbGetQuery(con, "SELECT * FROM metrics__append")
  expect_equal(nrow(rows), 1L)
  expect_identical(rows[["_mr_run_id"]], runs$run_id[1])
  expect_true(is.na(rows[["_mr_variant_label"]]))

  # Outputs JSON records the append as a structured entry.
  outs <- jsonlite::fromJSON(runs$outputs[1], simplifyVector = FALSE)
  expect_equal(length(outs), 1L)
  expect_equal(outs[[1]]$kind, "append_table")
  expect_equal(outs[[1]]$logical_name, "metrics")
  expect_equal(outs[[1]]$rows_appended, 1L)
})

test_that("stow() of a lazy tbl outside launch writes an interactive run row", {
  new_test_db()
  # Seed a base table via an interactive frame stow, then build a lazy tbl
  # from it and stow that. The lazy stow should also create an interactive
  # _mr_runs row (second row overall).
  stow(data.frame(x = 1:5), "base")
  lazy <- grab("base") |> dplyr::filter(.data$x >= 3)
  stow(lazy, "derived")

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(
    con, "SELECT step, status, outputs FROM _mr_runs ORDER BY started_at"
  )
  expect_equal(nrow(runs), 2L)
  expect_true(all(startsWith(runs$step, "<interactive:")))
  expect_equal(runs$status, c("interactive", "interactive"))

  rows <- grab("derived") |> dplyr::collect()
  expect_equal(nrow(rows), 3L)
})

test_that("a later launch that grabs an interactively-stowed frame warns about reproducibility", {
  new_test_db()
  stow(data.frame(x = 1:3), "train")

  reader <- write_script(c(
    "v <- grab('train') |> dplyr::collect()",
    "stow(data.frame(n = nrow(v)), 'y')"
  ))
  expect_warning(launch(reader), "stowed interactively")
})

test_that("grab() outside launch does not write a _mr_runs row (Shape B)", {
  new_test_db()
  launch({ stow(data.frame(n = 1:3), "x") })
  before <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  invisible(grab("x"))
  after <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  expect_equal(after, before)
})

test_that("launch does NOT warn when all inputs were produced by tracked runs (Shape B)", {
  new_test_db()
  # Write 'x' inside a tracked launch so its producer is a real script step.
  writer <- write_script("stow(data.frame(n = 1:3), 'x')")
  launch(writer)

  reader <- write_script(c(
    "v <- grab('x', run = 'all') |> dplyr::collect()",
    "stow(data.frame(n = nrow(v)), 'y')"
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
