## launch(... materialize = TRUE) wraps SQL as CREATE OR REPLACE TABLE.

test_that("materialize = TRUE produces kind = 'table' with row-content hash", {
  new_test_db()
  stow(data.frame(x = 1:5), "src")
  body <- "-- @inputs: src\n-- @output: out\nSELECT x * 10 AS y FROM src"
  launch(mr_sql(body), materialize = TRUE)

  rows <- mr_versions_rows("out")
  expect_equal(nrow(rows), 1L)
  expect_equal(rows$kind, "table")
  expect_true(!is.na(rows$source_sql))

  out <- grab("out") |> dplyr::collect()
  expect_setequal(out$y, c(10, 20, 30, 40, 50))
})

test_that("table and view modes round-trip identically through grab()/collect()", {
  new_test_db()
  stow(data.frame(x = 1:5), "src")
  view_body <- "-- @inputs: src\n-- @output: vout\nSELECT x AS y FROM src"
  tab_body  <- "-- @inputs: src\n-- @output: tout\nSELECT x AS y FROM src"
  launch(mr_sql(view_body))
  launch(mr_sql(tab_body), materialize = TRUE)
  expect_equal(
    grab("vout") |> dplyr::collect() |> as.data.frame(),
    grab("tout") |> dplyr::collect() |> as.data.frame()
  )
})

test_that("switching from view to table under same name is a namespace error", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  body <- "-- @inputs: src\n-- @output: out\nSELECT * FROM src"
  launch(mr_sql(body))                             # view
  # `force = TRUE` bypasses skip-on-fresh so the namespace guard
  # (the assertion under test) actually has a chance to fire.
  expect_error(
    launch(mr_sql(body), materialize = TRUE, force = TRUE),
    "already exists as a view"
  )
})

test_that("materialize = TRUE on a non-SQL launch is a no-op (not an error)", {
  new_test_db()
  # The launch emits its normal staleness / timing messages -- the
  # contract here is "no error", not "no message".
  expect_no_error(
    suppressMessages(launch({ stow(data.frame(x = 1), "y") },
                            materialize = TRUE))
  )
})
