## Helpers for parsing the JSON-encoded output pair lists on _mr_runs.
## append-shape outputs use the structured form {kind, logical_name, ...};
## versioned-shape outputs use {name, hash}. This parser handles both.
parse_output_names <- function(json) {
  if (is.na(json) || !nzchar(json)) return(character())
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  vapply(parsed, function(p) {
    if (!is.null(p$name)) p$name else p$logical_name
  }, character(1))
}

parse_input_names <- function(json) {
  if (is.na(json) || !nzchar(json)) return(character())
  parsed <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  vapply(parsed, function(p) p$name, character(1))
}

test_that("run record captures observed inputs/outputs and success status (append-shape)", {
  new_test_db()

  writer <- write_script(c(
    "stow(data.frame(x = 1), 'a')",
    "stow(data.frame(y = 2), 'b')"
  ))
  launch(writer)

  rw <- write_script(c(
    "a <- grab('a', run = 'all') |> dplyr::collect()",
    "stow(data.frame(z = nrow(a)), 'c')"
  ))
  launch(rw)

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT step, inputs, outputs, status FROM _mr_runs ORDER BY started_at")

  expect_equal(nrow(runs), 2L)
  expect_equal(runs$status, c("success", "success"))

  expect_length(parse_input_names(runs$inputs[1]), 0L)
  expect_setequal(parse_output_names(runs$outputs[1]), c("a", "b"))

  expect_equal(parse_input_names(runs$inputs[2]),   "a")
  expect_equal(parse_output_names(runs$outputs[2]), "c")
})

test_that("run record stores a positive duration and a valid timestamp", {
  new_test_db()
  s <- write_script(c("stow(data.frame(n = 1), 'x')"))
  launch(s)

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(con, "SELECT duration_ms, started_at FROM _mr_runs")
  expect_equal(nrow(runs), 1L)
  expect_true(!is.na(runs$duration_ms[1]))
  expect_gte(runs$duration_ms[1], 0)
  expect_true(inherits(runs$started_at[[1]], "POSIXct"))
})

test_that("_mr_runs has a nullable variant_label column", {
  new_test_db()

  con  <- .mr_get_connection()
  info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_runs)")
  expect_true("variant_label" %in% info$name)

  # New runs still write NULL until later slices opt in.
  script <- write_script('stow(data.frame(a = 1), "out")')
  launch(script)
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_true(all(is.na(row$variant_label)))
})
