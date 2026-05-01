test_that("stow() accepts a label parameter", {
  new_test_db()
  df <- data.frame(x = 1:3)
  expect_no_error(stow(df, "t", label = "fold_01"))
})

test_that("stow() rejects empty / whitespace label", {
  new_test_db()
  df <- data.frame(x = 1:3)
  expect_error(stow(df, "t", label = ""), "label")
  expect_error(stow(df, "t", label = "   "), "label")
})

test_that("stow() rejects non-character / non-scalar label", {
  new_test_db()
  df <- data.frame(x = 1:3)
  expect_error(stow(df, "t", label = 1L), "label")
  expect_error(stow(df, "t", label = c("a", "b")), "label")
  expect_error(stow(df, "t", label = NA_character_), "label")
})

test_that("stow() label flows to _mr_runs.variant_label for versioned frames", {
  new_test_db()
  con <- .mr_get_connection()

  stow(data.frame(x = 1L), "t", shape = "versioned", label = "fold_07")

  rows <- DBI::dbGetQuery(con,
    "SELECT variant_label FROM _mr_runs WHERE step LIKE '<interactive:%'")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows$variant_label[1], "fold_07")
})

test_that("stow() label flows to _mr_runs.variant_label for artifacts", {
  new_test_db()
  con <- .mr_get_connection()

  stow(list(model = "fake"), "m", label = "fold_07")

  rows <- DBI::dbGetQuery(con,
    "SELECT variant_label FROM _mr_runs WHERE step LIKE '<interactive:%'")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows$variant_label[1], "fold_07")
})

test_that("stow() with no label leaves variant_label NA", {
  new_test_db()
  con <- .mr_get_connection()

  stow(data.frame(x = 1L), "t", shape = "versioned")

  rows <- DBI::dbGetQuery(con,
    "SELECT variant_label FROM _mr_runs WHERE step LIKE '<interactive:%'")
  expect_identical(nrow(rows), 1L)
  expect_true(is.na(rows$variant_label[1]))
})
