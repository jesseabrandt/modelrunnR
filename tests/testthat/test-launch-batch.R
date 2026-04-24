## Batch launches: launch(rebind = mr_binds(...))

test_that("R-mode batch produces one run row per envelope (Shape B)", {
  new_test_db()
  # src is a Shape A rebind target (bare scalar coef values stowed as artifact)
  # model is an artifact (non-df list) stowed once per envelope.
  binds <- mr_binds(coef = c(1, 2, 3))
  result <- launch({
    coef_val <- grab("coef")
    fit <- list(coef = coef_val)
    stow(fit, "model")
  }, rebind = binds)

  expect_equal(nrow(result), 3L)
  expect_setequal(result$status, "success")
  # Three different coef values produce three distinct artifact versions.
  out_rows <- mr_versions_rows("model")
  expect_equal(nrow(out_rows), 3L)
})

test_that("batch records resolved rebinds JSON on every row (Shape B)", {
  new_test_db()

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

# Deleted: "SQL batch fans out one envelope per version of a rebound input"
# and "SQL batch with one bad rebind still records the others" —
# both used stow(data.frame(), "src") + mr_versions_rows("src") to get
# Shape A content hashes, then built mr_hash() rebinds. Shape B does not
# expose content hashes for df stow. SQL batch coverage for Shape A ingested
# sources would need ingest() rather than stow(); out of scope for Task 16.
