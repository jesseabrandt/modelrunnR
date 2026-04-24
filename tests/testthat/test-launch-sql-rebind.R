## launch(<sql>, rebind = list(...)) substitutes input names with the
## rebound version's physical name, producing a different content_hash.

test_that("rebind to mr_hash() rewrites the body and produces a new version", {
  new_test_db()
  .mr_stow_table("src", data.frame(x = 1:3))
  v1 <- mr_versions_rows("src")$content_hash[1]
  .mr_stow_table("src", data.frame(x = 100:103))              # new latest version

  body <- "-- @inputs: src\n-- @output: out\nSELECT * FROM src"
  default_run  <- launch(mr_sql(body), label = "def")
  rebound_run  <- launch(mr_sql(body), label = "reb",
                         rebind = list(src = mr_hash(v1)))

  out_rows <- mr_versions_rows("out")
  expect_equal(nrow(out_rows), 2L)
  expect_false(identical(out_rows$content_hash[1], out_rows$content_hash[2]))

  # The rebound run's view definition references the older src version's
  # physical name, not the latest's.
  reb_sql <- out_rows$source_sql[
    out_rows$content_hash != mr_versions_rows("out")$content_hash[1]
  ]
  expect_match(reb_sql[1], "src__")
})

test_that("rebind referencing a name not in @inputs errors", {
  new_test_db()
  .mr_stow_table("src", data.frame(x = 1:3))
  body <- "-- @inputs: src\n-- @output: out\nSELECT * FROM src"
  expect_error(
    launch(mr_sql(body), rebind = list(other = data.frame(z = 1))),
    "@inputs"
  )
})

test_that("word-boundary substitution does not rewrite suffixed identifiers", {
  new_test_db()
  # Two distinct versions of `panel` must already exist before the
  # default launch, so default-vs-rebound SELECT bodies actually
  # differ in their substituted physical names.
  .mr_stow_table("panel", data.frame(panel = 1:3))
  v1 <- mr_versions_rows("panel")$content_hash[1]
  .mr_stow_table("panel", data.frame(panel = 100:103))          # v2 = latest
  body <- "-- @inputs: panel\n-- @output: out\nSELECT panel AS panel_alt FROM panel"

  launch(mr_sql(body))                                # default → v2 physical
  default_sql <- mr_versions_rows("out")$source_sql[1]

  launch(mr_sql(body), label = "alt",
         rebind = list(panel = mr_hash(v1)))         # rebind → v1 physical
  alt_sql <- mr_versions_rows("out")$source_sql[2]

  # `panel_alt` (the column alias) MUST still appear unchanged in both.
  expect_match(default_sql, "AS panel_alt")
  expect_match(alt_sql, "AS panel_alt")
  # The FROM-side identifier was rewritten in the rebound case.
  expect_match(alt_sql, "FROM \"panel__")
})
