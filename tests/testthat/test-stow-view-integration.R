test_that("rolling-window pattern: per-fold views + mr_variant rebind", {
  new_test_db()
  con <- .mr_get_connection()

  # Source panel: 11 years.
  stow(data.frame(year = 2014:2024, x = seq_len(11)), "panel",
       shape = "versioned")

  # Two folds: train on 2014-2020/test 2021, train on 2015-2021/test 2022.
  windows <- data.frame(
    fold             = 1:2,
    train_start_year = c(2014L, 2015L),
    train_end_year   = c(2020L, 2021L),
    test_year        = c(2021L, 2022L)
  )

  # Pre-stow per-fold views.
  for (i in seq_len(nrow(windows))) {
    fold_label  <- sprintf("fold_%02d", windows$fold[i])
    train_start <- windows$train_start_year[i]
    train_end   <- windows$train_end_year[i]
    test_yr     <- windows$test_year[i]
    panel <- grab("panel")
    panel |>
      dplyr::filter(year >= train_start, year <= train_end) |>
      stow("train", shape = "view", label = fold_label)
    panel |>
      dplyr::filter(year == test_yr) |>
      stow("test", shape = "view", label = fold_label)
  }

  # The two folds produced two variants of `train` and `test`.
  variants <- DBI::dbGetQuery(con,
    "SELECT DISTINCT variant_label FROM _mr_runs
      WHERE variant_label LIKE 'fold_%' ORDER BY variant_label")
  expect_identical(variants$variant_label, c("fold_01", "fold_02"))

  # Each variant resolves to a distinct view hash.
  for (i in seq_len(nrow(windows))) {
    fold_label <- sprintf("fold_%02d", windows$fold[i])
    h_train <- .mr_latest_hash_for_variant(con, "train", fold_label)
    h_test  <- .mr_latest_hash_for_variant(con, "test",  fold_label)
    expect_false(is.null(h_train))
    expect_false(is.null(h_test))
  }

  # And the launch-side rebind path resolves cleanly:
  out <- launch({
    df <- grab("train") |> dplyr::collect()
    stow(data.frame(n_rows = nrow(df)), "fold_metric", shape = "append")
  }, rebind = list(train = mr_variant("fold_01")), label = "fold_01")
  expect_identical(out$status, "success")

  metric_rows <- DBI::dbGetQuery(con,
    "SELECT n_rows, \"_mr_variant_label\" FROM fold_metric__append
      ORDER BY \"_mr_variant_label\"")
  expect_identical(metric_rows$n_rows[1], 7L)  # 2014..2020
  expect_identical(metric_rows[["_mr_variant_label"]][1], "fold_01")
})
