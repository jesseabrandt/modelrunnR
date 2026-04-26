test_that("runs() against an empty store returns a zero-row tibble with mr_code on code_body", {
  new_test_db()

  out <- runs()
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 0L)
  expect_true("code_body" %in% names(out))
  expect_s3_class(out$code_body, "mr_code")
})

test_that("runs() returns a tibble after launch() populates _mr_runs", {
  new_test_db()

  launch({ stow(data.frame(x = 1:3), "out_a") })
  launch({ stow(data.frame(x = 4:6), "out_b") })

  out <- runs()
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 2L)
  expect_true(all(c("run_id", "step", "code_body", "started_at", "status") %in% names(out)))
})

test_that("runs()$code_body has class mr_code", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  out <- runs()
  expect_s3_class(out$code_body, "mr_code")
})

test_that("pull(code_body) yields an mr_code-classed character", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  body <- dplyr::pull(runs(), code_body)
  expect_s3_class(body, "mr_code")
  expect_type(unclass(body), "character")
  expect_equal(length(body), 1L)
})

test_that("DBI::dbReadTable on _mr_runs still returns a plain character (DB unchanged)", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  con <- .mr_get_connection()
  raw <- DBI::dbReadTable(con, "_mr_runs")
  expect_type(raw$code_body, "character")
  expect_false(inherits(raw$code_body, "mr_code"))
})

test_that("runs() round-trips code_body identically to dbReadTable (modulo class)", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out_a") })
  launch({ stow(data.frame(x = 2), "out_b") })

  con <- .mr_get_connection()
  raw <- DBI::dbReadTable(con, "_mr_runs")
  out <- runs()

  raw_sorted <- raw[order(raw$run_id), , drop = FALSE]
  out_sorted <- out[order(out$run_id), , drop = FALSE]

  expect_identical(as.character(out_sorted$code_body), raw_sorted$code_body)
})

test_that("runs() surfaces all _mr_runs columns (no subsetting)", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  con <- .mr_get_connection()
  schema_cols <- DBI::dbListFields(con, "_mr_runs")
  expect_setequal(names(runs()), schema_cols)
})

test_that("JSON-shaped columns stay raw character", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  out <- runs()
  for (col in c("inputs", "outputs", "session_info", "attached_packages")) {
    if (col %in% names(out)) {
      expect_type(out[[col]], "character")
      expect_false(inherits(out[[col]], "mr_code"))
    }
  }
})

test_that("downstream dplyr filter on runs() works as expected", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") }, label = "alpha")
  launch({ stow(data.frame(x = 2), "out") }, label = "beta")

  filtered <- dplyr::filter(runs(), variant_label == "alpha")
  expect_equal(nrow(filtered), 1L)
  expect_s3_class(filtered$code_body, "mr_code")
})
