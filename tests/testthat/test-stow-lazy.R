test_that("stow(lazy_tbl, name) realizes the tbl server-side (Shape B)", {
  new_test_db()

  # Write raw data via a launch.
  launch({ stow(data.frame(g = rep(letters[1:3], each = 4), v = 1:12), "raw") })

  # Summarize with a lazy pipeline and stow the result (also inside launch).
  # grab("raw", run = "all") bypasses the launch-context filter so the
  # summarize has the full raw table to work with.
  launch({
    grab("raw", run = "all") |>
      dplyr::group_by(g) |>
      dplyr::summarise(total = sum(v), .groups = "drop") |>
      stow("summary")
  })

  got <- grab("summary", run = "all") |> dplyr::collect()
  expect_equal(nrow(got), 3L)
  expect_setequal(got$g, c("a", "b", "c"))
  # run = "all" exposes system columns as user-facing run_id / variant_label.
  expect_true(all(c("g", "total", "run_id") %in% colnames(got)))
})

test_that("stow(lazy_tbl) on a foreign connection errors clearly (Shape B)", {
  new_test_db()

  # The inline block's parent is globalenv(), not the test frame, so we
  # place the foreign tbl in globalenv() temporarily.
  other <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(other, shutdown = TRUE), add = TRUE)
  DBI::dbWriteTable(other, "other_t", data.frame(x = 1:3))
  assign(".mr_test_foreign_tbl", dplyr::tbl(other, "other_t"), envir = globalenv())
  on.exit(rm(".mr_test_foreign_tbl", envir = globalenv()), add = TRUE)

  expect_error(
    launch({ stow(.mr_test_foreign_tbl, "bogus") }),
    "different DBI connection"
  )
})

test_that("source_sql is NULL for artifact stows", {
  new_test_db()
  stow(list(a = 1, b = 2), "art")
  rows <- mr_versions_rows("art")
  expect_true(is.na(rows$source_sql[1]))
})

test_that("lazy stow records an output entry on the run row (Shape B)", {
  new_test_db()
  launch({ stow(data.frame(x = 1:5), "raw") })

  run <- launch(
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
  # Shape B outputs carry logical_name, not name
  names_out <- vapply(outputs, function(p) {
    if (!is.null(p$logical_name)) p$logical_name else p$name
  }, character(1))
  expect_true("filtered" %in% names_out)
})
