# tests/testthat/test-stow-versioned-frame.R

test_that("stow(df, name, shape = 'versioned') lands in _mr_versions, not append-shape", {
  new_test_db()

  df <- data.frame(x = 1:3, y = letters[1:3])
  stow(df, "training", shape = "versioned")

  # Versioned-shape: one row in _mr_versions with kind = 'table'.
  rows <- mr_versions_rows("training")
  expect_equal(nrow(rows), 1L)
  expect_equal(rows$kind[1], "table")

  # Source columns are NULL for in-memory writes.
  expect_true(is.na(rows$source_uri[1]))
  expect_true(is.na(rows$source_hash[1]))

  # grab() returns the data.
  got <- grab("training") |> dplyr::collect()
  expect_equal(got$x, 1:3)
  expect_equal(as.character(got$y), letters[1:3])
})

test_that("re-stowing identical content is a no-op (last_seen update only)", {
  new_test_db()
  df <- data.frame(x = 1:3)

  stow(df, "training", shape = "versioned")
  stow(df, "training", shape = "versioned")

  expect_equal(nrow(versions("training")), 1L)
})

test_that("two distinct frames produce two version rows", {
  new_test_db()

  stow(data.frame(x = 1:3), "training", shape = "versioned")
  stow(data.frame(x = 4:6), "training", shape = "versioned")

  expect_equal(nrow(versions("training")), 2L)
})

test_that("frames default to append-shape when shape is unspecified", {
  # Regression guard: adding the shape arg must not flip the default.
  new_test_db()
  .mr_start_recording(run_id = "run_1", variant_label = "lm")
  on.exit(.mr_stop_recording(), add = TRUE)

  stow(data.frame(x = 1:3), "metrics")

  # Append-shape: nothing in _mr_versions; data lives in the append
  # accumulator surfaced by versions() under append semantics.
  vrows <- mr_versions_rows("metrics")
  expect_equal(nrow(vrows), 0L)
})
