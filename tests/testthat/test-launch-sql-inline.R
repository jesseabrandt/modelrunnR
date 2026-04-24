## Inline-mode SQL launches: launch(mr_sql("..."))

test_that("launch(mr_sql(...)) registers a view and round-trips", {
  new_test_db()
  .mr_stow_table("src", data.frame(x = 1:3))
  body <- "-- @inputs: src\n-- @output: doubled\nSELECT x * 2 AS y FROM src"
  run_row <- launch(mr_sql(body))

  expect_equal(run_row$status, "success")
  expect_match(run_row$step, "^<inline:sql:")
  expect_equal(nrow(mr_versions_rows("doubled")), 1L)

  out <- grab("doubled") |> dplyr::collect()
  expect_setequal(out$y, c(2, 4, 6))
})

test_that("inline SQL without @output errors", {
  new_test_db()
  .mr_stow_table("src", data.frame(x = 1:3))
  expect_error(
    launch(mr_sql("-- @inputs: src\nSELECT * FROM src")),
    "@output"
  )
})

test_that("step encodes a 12-char prefix and uses 'sql:' infix", {
  new_test_db()
  .mr_stow_table("src", data.frame(x = 1:3))
  run_row <- launch(mr_sql("-- @inputs: src\n-- @output: o\nSELECT * FROM src"))
  expect_match(run_row$step, "^<inline:sql:[0-9a-f]{12}>$")
})

test_that("re-running identical inline SQL is fresh", {
  new_test_db()
  .mr_stow_table("src", data.frame(x = 1:3))
  body <- "-- @inputs: src\n-- @output: o\nSELECT * FROM src"
  first  <- launch(mr_sql(body), label = "v1")
  second <- launch(mr_sql(body), label = "v1")
  expect_equal(first$status, "success")
  expect_equal(second$status, "skipped_fresh")
})

test_that("mr_sql() outside launch() is just a classed object (no side effects)", {
  new_test_db()
  before <- nrow(mr_versions_rows())
  s <- mr_sql("SELECT 1")
  expect_s3_class(s, "mr_ref_sql")
  expect_equal(nrow(mr_versions_rows()), before)
})
