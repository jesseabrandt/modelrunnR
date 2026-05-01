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

test_that("stow(shape = 'view') is callable from user code with a label", {
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(year = 2014:2024, x = 1:11), "panel", shape = "versioned")

  panel <- grab("panel")
  hash  <- panel |>
    dplyr::filter(year <= 2020) |>
    stow("train", shape = "view", label = "fold_07")

  vrow <- DBI::dbGetQuery(con,
    "SELECT physical_name FROM _mr_versions WHERE logical_name = 'train'")
  expect_identical(nrow(vrow), 1L)
  expect_true(DBI::dbExistsTable(con, vrow$physical_name[1]))

  rows <- DBI::dbGetQuery(con,
    sprintf("SELECT count(*) AS n FROM %s",
            DBI::dbQuoteIdentifier(con, vrow$physical_name[1])))
  expect_identical(as.integer(rows$n[1]), 7L)

  rrow <- DBI::dbGetQuery(con,
    "SELECT variant_label FROM _mr_runs
      WHERE step LIKE '<interactive:%' AND variant_label = 'fold_07'")
  expect_identical(nrow(rrow), 1L)
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

test_that(".mr_stow_view registers a view and writes a run row", {
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(year = 2014:2024, x = 1:11), "panel", shape = "versioned")

  panel <- grab("panel")
  hash  <- .mr_stow_view("train", panel |> dplyr::filter(year <= 2020),
                         label = "fold_07")

  expect_type(hash, "character")
  expect_match(hash, "^[a-f0-9]+$")

  vrow <- DBI::dbGetQuery(con,
    "SELECT * FROM _mr_versions WHERE logical_name = 'train'")
  expect_identical(nrow(vrow), 1L)
  expect_identical(vrow$kind[1], "view")
  expect_identical(vrow$content_hash[1], hash)

  expect_true(DBI::dbExistsTable(con, vrow$physical_name[1]))

  rrow <- DBI::dbGetQuery(con,
    "SELECT step, variant_label, inputs, outputs FROM _mr_runs
      WHERE step LIKE '<interactive:%'")
  # We expect TWO interactive rows: one from the panel stow, one from the view stow.
  expect_gte(nrow(rrow), 2L)

  view_run <- rrow[!is.na(rrow$variant_label) & rrow$variant_label == "fold_07", ]
  expect_identical(nrow(view_run), 1L)

  inputs <- jsonlite::fromJSON(view_run$inputs[1], simplifyVector = FALSE)
  expect_length(inputs, 1L)
  expect_identical(inputs[[1]]$name, "panel")

  outputs <- jsonlite::fromJSON(view_run$outputs[1], simplifyVector = FALSE)
  expect_length(outputs, 1L)
  expect_identical(outputs[[1]]$name, "train")
  expect_identical(outputs[[1]]$hash, hash)
})

test_that(".mr_stow_view errors when expression has no managed source", {
  new_test_db()
  con <- .mr_get_connection()
  DBI::dbExecute(con, "CREATE TABLE rogue (x INTEGER)")
  rogue <- dplyr::tbl(con, "rogue")

  expect_error(
    .mr_stow_view("train", rogue |> dplyr::filter(x > 0)),
    "no modelrunnR-managed inputs"
  )
})

test_that(".mr_stow_view handles dbplyr-rendered SQL with quoted identifiers", {
  # Regression: dbplyr's sql_render() emits double-quoted physical names
  # (e.g. "panel__abc123"). Without quote-stripping, the sniffer would
  # tokenize them as separate `panel` and `abc123` words and miss the
  # match. This test locks in the fix.
  new_test_db()
  con <- .mr_get_connection()
  stow(data.frame(year = 2014:2024, x = 1:11), "panel", shape = "versioned")

  panel <- grab("panel")
  expect_no_error(
    .mr_stow_view("train", panel |> dplyr::filter(year <= 2020))
  )
})
