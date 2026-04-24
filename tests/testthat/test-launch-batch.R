## Batch launches: launch(rebind = mr_binds(...))

test_that("R-mode batch produces one run row per envelope", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")

  binds <- mr_binds(coef = c(1, 2, 3))
  result <- launch({
    df <- grab("src") |> dplyr::collect()
    fit <- list(coef = grab("coef"), n = nrow(df))
    stow(fit, "model")
  }, rebind = binds)

  expect_equal(nrow(result), 3L)
  expect_setequal(result$status, "success")
  # Three different `coef` values produced three distinct outputs.
  out_rows <- mr_versions_rows("model")
  expect_equal(nrow(out_rows), 3L)
})

test_that("batch records resolved rebinds JSON on every row", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")

  binds <- mr_binds(coef = c(0.1, 0.5))
  result <- launch({
    coef <- grab("coef")
    stow(list(c = coef), "model")
  }, rebind = binds)

  expect_equal(nrow(result), 2L)
  for (k in seq_len(nrow(result))) {
    rb <- jsonlite::fromJSON(result$rebinds[k], simplifyVector = FALSE)
    expect_length(rb, 1L)
    expect_equal(rb[[1]]$name, "coef")
    expect_equal(rb[[1]]$source, "literal")
  }
})

test_that("batch with explicit .labels carries them through", {
  new_test_db()
  binds <- mr_binds(x = c(1, 2, 3), .labels = c("low", "mid", "high"))
  result <- launch({
    stow(list(v = grab("x")), "out")
  }, rebind = binds)
  expect_setequal(result$variant_label, c("low", "mid", "high"))
})

test_that("batch error in one envelope doesn't halt the loop", {
  new_test_db()
  binds <- mr_binds(x = c("ok1", "boom", "ok3"))
  expect_error(
    launch({
      v <- grab("x")
      if (identical(v, "boom")) stop("explosion")
      stow(list(v = v), "out")
    }, rebind = binds),
    "1/3 errored"
  )
  # All three batch runs wrote a row; one is status='error', two are
  # status='success'. The batch was triggered by a single inline block,
  # so step is the same across the three rows.
  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(con,
    "SELECT status FROM _mr_runs WHERE step LIKE '<inline:%' ORDER BY started_at"
  )
  expect_true(any(rows$status == "error"))
  expect_true(sum(rows$status == "success") >= 2L)
})

test_that("on_error = 'warn' demotes the final error to a warning", {
  new_test_db()
  binds <- mr_binds(x = c("ok1", "boom"))
  expect_warning(
    launch({
      v <- grab("x")
      if (identical(v, "boom")) stop("explosion")
      stow(list(v = v), "out")
    }, rebind = binds, on_error = "warn"),
    "1/2 errored"
  )
})

test_that("on_error outside batch mode is an error", {
  new_test_db()
  expect_error(
    launch({ stow(data.frame(x = 1), "y") }, on_error = "warn"),
    "on_error only applies"
  )
})

test_that("batch + cross mode produces N1 * N2 envelopes", {
  new_test_db()
  binds <- mr_binds(a = 1:2, b = c(10, 20, 30), mode = "cross")
  result <- launch({
    stow(list(s = grab("a") + grab("b")), "out")
  }, rebind = binds)
  expect_equal(nrow(result), 6L)
})

test_that("force = TRUE applies to every envelope in the batch", {
  new_test_db()
  binds <- mr_binds(x = 1:2)
  body <- function() launch({
    stow(list(v = grab("x")), "out")
  }, rebind = binds, label = "v")

  body()
  res2 <- body()
  expect_setequal(res2$status, "skipped_fresh")

  res3 <- launch({
    stow(list(v = grab("x")), "out")
  }, rebind = binds, label = "v", force = TRUE)
  expect_setequal(res3$status, "success")
})

test_that("SQL batch fans out one envelope per version of a rebound input", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  v1 <- mr_versions_rows("src")$content_hash[1]
  stow(data.frame(x = 100:103), "src")            # v2 = latest
  v2 <- mr_versions_rows("src")$content_hash[2]

  binds <- mr_envelopes(
    list(.label = "v1_count", src = mr_hash(v1)),
    list(.label = "v2_count", src = mr_hash(v2))
  )
  result <- launch(
    mr_sql("-- @inputs: src\n-- @output: counted\nSELECT COUNT(*) AS n FROM src"),
    rebind = binds
  )
  expect_equal(nrow(result), 2L)
  expect_setequal(result$status, "success")
  out_rows <- mr_versions_rows("counted")
  expect_equal(nrow(out_rows), 2L)
})

test_that("batch_id groups every envelope of one launch() and differs across calls", {
  new_test_db()
  binds <- mr_binds(x = 1:3)
  body <- function() launch({
    stow(list(v = grab("x")), "out")
  }, rebind = binds, force = TRUE)

  res1 <- body()
  res2 <- body()

  # Same batch -> same id on every row.
  expect_length(unique(res1$batch_id), 1L)
  expect_false(is.na(res1$batch_id[1]))
  expect_length(unique(res2$batch_id), 1L)

  # Different launch() calls -> different ids, so a downstream consumer
  # can disambiguate two interleaved batches with the same labels.
  expect_false(identical(res1$batch_id[1], res2$batch_id[1]))
})

test_that("single (non-batch) launch leaves batch_id NA", {
  new_test_db()
  res <- launch({ stow(list(v = 1), "out") })
  expect_true(is.na(res$batch_id))
})

test_that("SQL batch shares a single batch_id across envelopes", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  v1 <- mr_versions_rows("src")$content_hash[1]
  stow(data.frame(x = 100:103), "src")
  v2 <- mr_versions_rows("src")$content_hash[2]

  binds <- mr_envelopes(
    list(.label = "v1_count", src = mr_hash(v1)),
    list(.label = "v2_count", src = mr_hash(v2))
  )
  result <- launch(
    mr_sql("-- @inputs: src\n-- @output: counted\nSELECT COUNT(*) AS n FROM src"),
    rebind = binds
  )
  expect_length(unique(result$batch_id), 1L)
  expect_false(is.na(result$batch_id[1]))
})

test_that("batch_id is set even for envelopes that error or skip-fresh", {
  new_test_db()

  # First batch: one envelope errors. The errored row still belongs to
  # the same batch and must carry the same batch_id as its siblings.
  binds <- mr_binds(x = c("ok1", "boom", "ok3"))
  expect_error(
    launch({
      v <- grab("x")
      if (identical(v, "boom")) stop("explosion")
      stow(list(v = v), "out")
    }, rebind = binds),
    "1/3 errored"
  )

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(con,
    "SELECT status, batch_id FROM _mr_runs ORDER BY started_at"
  )
  expect_length(unique(rows$batch_id), 1L)
  expect_true("error" %in% rows$status)

  # Re-run the first batch with the same envelopes + label so the
  # successful envelopes record as skipped_fresh on the second pass.
  # The skip rows must also carry the new batch_id (not NA, not the
  # old batch's id).
  binds_ok <- mr_binds(x = c("ok1", "ok3"))
  res_seed <- launch({
    stow(list(v = grab("x")), "out")
  }, rebind = binds_ok, label = "rerun")
  expect_setequal(res_seed$status, "success")

  res_skip <- launch({
    stow(list(v = grab("x")), "out")
  }, rebind = binds_ok, label = "rerun")
  expect_setequal(res_skip$status, "skipped_fresh")
  expect_length(unique(res_skip$batch_id), 1L)
  expect_false(is.na(res_skip$batch_id[1]))
  expect_false(identical(res_skip$batch_id[1], res_seed$batch_id[1]))
})

test_that("SQL batch with one bad rebind still records the others", {
  new_test_db()
  stow(data.frame(x = 1:3), "src")
  v1 <- mr_versions_rows("src")$content_hash[1]

  binds <- mr_envelopes(
    list(.label = "ok",  src = mr_hash(v1)),
    list(.label = "bad", src = mr_hash("ffffffff_not_a_real_hash"))
  )
  expect_error(
    launch(
      mr_sql("-- @inputs: src\n-- @output: counted\nSELECT COUNT(*) AS n FROM src"),
      rebind = binds
    ),
    "1/2 errored"
  )
  expect_equal(nrow(mr_versions_rows("counted")), 1L)
})
