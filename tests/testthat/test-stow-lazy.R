test_that("stow(lazy_tbl, name) realizes the tbl server-side", {
  new_test_db()
  df <- data.frame(g = rep(letters[1:3], each = 4), v = 1:12)
  stow(df, "raw")

  grab("raw") |>
    dplyr::group_by(g) |>
    dplyr::summarise(total = sum(v), .groups = "drop") |>
    stow("summary")

  rows <- mr_versions_rows("summary")
  expect_equal(nrow(rows), 1L)
  expect_equal(rows$kind, "table")
  expect_false(is.na(rows$source_sql[1]))
  expect_match(rows$source_sql[1], "SELECT|GROUP BY", ignore.case = TRUE)

  got <- grab("summary") |> dplyr::collect()
  expect_equal(nrow(got), 3L)
  expect_setequal(names(got), c("g", "total"))
})

test_that("stow(lazy_tbl) on a foreign connection errors clearly", {
  new_test_db()
  df <- data.frame(x = 1:3)
  stow(df, "t")

  other <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(other, shutdown = TRUE))
  DBI::dbWriteTable(other, "other_t", data.frame(x = 1:3))
  foreign_tbl <- dplyr::tbl(other, "other_t")

  expect_error(
    stow(foreign_tbl, "bogus"),
    "different DBI connection"
  )
})

test_that("source_sql is NULL for materialized-frame stows", {
  new_test_db()
  stow(data.frame(x = 1:3), "mat")
  rows <- mr_versions_rows("mat")
  expect_true(is.na(rows$source_sql[1]))
})

test_that("source_sql is NULL for artifact stows", {
  new_test_db()
  stow(list(a = 1, b = 2), "art")
  rows <- mr_versions_rows("art")
  expect_true(is.na(rows$source_sql[1]))
})

test_that("lazy stow records an output pair on the run row", {
  new_test_db()
  stow(data.frame(x = 1:5), "raw")

  launch(
    {
      grab("raw") |>
        dplyr::filter(x > 2) |>
        stow("filtered")
    },
    label = "lazy_stow"
  )

  con <- .mr_get_connection()
  runs <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE variant_label = 'lazy_stow' ORDER BY started_at DESC LIMIT 1"
  )
  outputs <- jsonlite::fromJSON(runs$outputs[1], simplifyVector = FALSE)
  names_out <- vapply(outputs, function(p) p$name, character(1))
  expect_true("filtered" %in% names_out)
})
