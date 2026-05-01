test_that("stow() rejects shape = 'view' for non-lazy values", {
  new_test_db()
  expect_error(
    stow(data.frame(x = 1:3), "t", shape = "view"),
    "view.*lazy"
  )
  expect_error(
    stow(list(model = "fake"), "m", shape = "view"),
    "view.*lazy"
  )
})

test_that("stow() shape = 'view' raises 'not yet implemented' for lazy values (Task 4 placeholder)", {
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(year = 2014:2024, x = 1:11), "panel")
  panel <- grab("panel")

  expect_error(
    panel |> dplyr::filter(year <= 2020) |> stow("train", shape = "view"),
    "not yet implemented"
  )
})

test_that(".mr_sniff_view_inputs finds versioned-shape physical names", {
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(x = 1:3), "panel", shape = "versioned")

  pn <- DBI::dbGetQuery(con,
    "SELECT physical_name, content_hash FROM _mr_versions WHERE logical_name = 'panel'")
  rendered <- sprintf("SELECT * FROM %s WHERE x > 1", pn$physical_name[1])

  inputs <- .mr_sniff_view_inputs(con, rendered)
  expect_length(inputs, 1L)
  expect_identical(inputs[[1]]$name, "panel")
  expect_identical(inputs[[1]]$hash, pn$content_hash[1])
})

test_that(".mr_sniff_view_inputs finds append-shape physical names with NA hash", {
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(year = 2014:2020), "panel", shape = "append")

  rendered <- "SELECT * FROM panel__append WHERE year < 2020"

  inputs <- .mr_sniff_view_inputs(con, rendered)
  expect_length(inputs, 1L)
  expect_identical(inputs[[1]]$name, "panel")
  expect_true(is.na(inputs[[1]]$hash))
})

test_that(".mr_sniff_view_inputs errors when no managed names are referenced", {
  new_test_db()
  con <- .mr_get_connection()
  expect_error(
    .mr_sniff_view_inputs(con, "SELECT 1 AS x FROM unmanaged_table"),
    "no modelrunnR-managed inputs"
  )
})
