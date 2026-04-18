test_that("duckdb_seed makes slice_sample reproducible across runs", {
  new_test_db()
  df <- data.frame(id = 1:1000, v = rnorm(1000))
  stow(df, "big")

  launch(
    {
      grab("big") |>
        dplyr::slice_sample(n = 20) |>
        stow("sample_a")
    },
    label = "seeded_a", duckdb_seed = 0.42, force = TRUE
  )
  hash_a <- mr_versions_rows("sample_a")$content_hash[1]

  # Clear and re-run under the same seed; the sample should be byte-identical.
  launch(
    {
      grab("big") |>
        dplyr::slice_sample(n = 20) |>
        stow("sample_b")
    },
    label = "seeded_b", duckdb_seed = 0.42, force = TRUE
  )
  hash_b <- mr_versions_rows("sample_b")$content_hash[1]

  expect_identical(hash_a, hash_b)
})

test_that("different duckdb_seeds produce different samples", {
  new_test_db()
  stow(data.frame(id = 1:1000, v = rnorm(1000)), "big")

  launch(
    { grab("big") |> dplyr::slice_sample(n = 20) |> stow("s1") },
    label = "seed_x", duckdb_seed = 0.10, force = TRUE
  )
  launch(
    { grab("big") |> dplyr::slice_sample(n = 20) |> stow("s2") },
    label = "seed_y", duckdb_seed = 0.90, force = TRUE
  )

  h1 <- mr_versions_rows("s1")$content_hash[1]
  h2 <- mr_versions_rows("s2")$content_hash[1]
  expect_false(identical(h1, h2))
})

test_that("out-of-range duckdb_seed errors", {
  new_test_db()
  expect_error(
    launch({ 1 + 1 }, duckdb_seed = 2),
    "duckdb_seed must be in \\[-1, 1\\]"
  )
  expect_error(
    launch({ 1 + 1 }, duckdb_seed = -1.5),
    "duckdb_seed must be in \\[-1, 1\\]"
  )
})

test_that("run row records the duckdb_seed value", {
  new_test_db()
  launch({ 1 + 1 }, label = "record_seed", duckdb_seed = 0.33)

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con,
    "SELECT duckdb_seed FROM _mr_runs WHERE variant_label = 'record_seed'"
  )
  expect_equal(rows$duckdb_seed[1], 0.33)
})

test_that("omitting duckdb_seed leaves the column NA", {
  new_test_db()
  launch({ 1 + 1 }, label = "no_seed")

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con,
    "SELECT duckdb_seed FROM _mr_runs WHERE variant_label = 'no_seed'"
  )
  expect_true(is.na(rows$duckdb_seed[1]))
})
