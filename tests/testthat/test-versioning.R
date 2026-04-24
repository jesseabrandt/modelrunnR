physical_tables <- function(pattern = "__") {
  con <- .mr_get_connection()
  tbls <- .mr_list_tables(con)
  grep(pattern, tbls, value = TRUE, fixed = TRUE)
}

test_that("stowing the same frame twice yields one physical table and one version row", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(x = 1:5, y = letters[1:5], stringsAsFactors = FALSE)
  stow(df, "t")
  Sys.sleep(0.01)
  stow(df, "t")

  vrows <- mr_versions_rows("t")
  expect_equal(nrow(vrows), 1L)
  expect_equal(vrows$kind, "table")
  expect_true(vrows$last_seen >= vrows$first_seen)

  # Exactly one hash-suffixed physical table for "t".
  pt <- physical_tables()
  expect_equal(length(grep("^t__", pt)), 1L)
})

test_that("stowing a modified frame yields a second physical table and version row", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1:3), "t")
  stow(data.frame(x = c(1L, 2L, 9L)), "t")

  vrows <- mr_versions_rows("t")
  expect_equal(nrow(vrows), 2L)
  expect_false(identical(vrows$content_hash[1], vrows$content_hash[2]))

  pt <- physical_tables()
  expect_equal(length(grep("^t__", pt)), 2L)

  # Default grab returns the most recent version (by first_seen).
  latest <- grab("t") |> dplyr::collect()
  expect_equal(latest$x, c(1L, 2L, 9L))
})

test_that("hash is stable across row and column reorderings", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df1 <- data.frame(a = 1:3, b = c("x", "y", "z"), stringsAsFactors = FALSE)
  df2 <- df1[c(3, 1, 2), c("b", "a")]
  rownames(df2) <- NULL

  stow(df1, "ordered")
  stow(df2, "ordered")

  vrows <- mr_versions_rows("ordered")
  expect_equal(nrow(vrows), 1L)  # row and column reorderings do NOT produce a new version
})

test_that("grab(version = h) returns exactly that hash's frame", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1:2), "t")
  stow(data.frame(x = c(10L, 20L)), "t")

  vrows <- mr_versions_rows("t")
  expect_equal(nrow(vrows), 2L)

  older <- vrows$content_hash[1]
  newer <- vrows$content_hash[2]

  expect_equal(dplyr::collect(grab("t", version = older))$x, 1:2)
  expect_equal(dplyr::collect(grab("t", version = newer))$x, c(10L, 20L))
  expect_equal(dplyr::collect(grab("t"))$x, c(10L, 20L))
})

test_that("grab(from_run = rid) returns what that run produced", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  script <- write_script(c(
    "v <- get0('v', envir = globalenv(), ifnotfound = 1L)",
    "stow(data.frame(x = seq_len(v)), 'seq')"
  ))

  # force = TRUE because `v` is a global the block reads but isn't declared
  # as an external input -- modelrunnR correctly sees the step as fresh.
  # This test verifies `from_run` semantics, not staleness.
  r1 <- launch(script); assign("v", 2L, envir = globalenv())
  r2 <- launch(script, force = TRUE); assign("v", 3L, envir = globalenv())
  r3 <- launch(script, force = TRUE)

  on.exit(rm("v", envir = globalenv()), add = TRUE)

  expect_equal(dplyr::collect(grab("seq", from_run = r1$run_id))$x, 1L)
  expect_equal(dplyr::collect(grab("seq", from_run = r2$run_id))$x, 1:2)
  expect_equal(dplyr::collect(grab("seq", from_run = r3$run_id))$x, 1:3)
})

test_that("grab(as_of = ts) returns the version latest at that time", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1L), "t")
  t1 <- Sys.time()
  Sys.sleep(0.05)
  stow(data.frame(x = 2L), "t")
  Sys.sleep(0.05)
  t2 <- Sys.time()
  stow(data.frame(x = 3L), "t")

  expect_equal(dplyr::collect(grab("t", as_of = t1))$x, 1L)
  expect_equal(dplyr::collect(grab("t", as_of = t2))$x, 2L)
  expect_equal(dplyr::collect(grab("t"))$x, 3L)
})

test_that("grab() errors cleanly when a name has never been stowed", {
  new_test_db()
  expect_error(grab("ghost"), "no value stowed")
})

test_that("grab(version = ...) errors cleanly when the hash is unknown", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1), "t")
  expect_error(grab("t", version = "deadbeef"), "version")
})

test_that("grab(from_run=) with NULL/empty outputs errors cleanly, not a JSON crash", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1), "t")
  # Hand-insert a fake run row with NULL outputs to simulate legacy data.
  con <- .mr_get_connection()
  DBI::dbExecute(
    con,
    "INSERT INTO _mr_runs (step, run_id, inputs, outputs, started_at, duration_ms, status)
     VALUES ('fake.R', 'fake_run', '[]', NULL, ?, 0, 'success')",
    params = list(Sys.time())
  )
  expect_error(grab("t", from_run = "fake_run"), "did not produce")
})

test_that("grab(as_of = 'string') is reproducible across session TZ", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1L), "t")
  Sys.sleep(0.05)
  stow(data.frame(x = 2L), "t")

  # Both invocations must resolve identically to the UTC-parsed timestamp.
  withr::with_envvar(c(TZ = "UTC"), {
    r_utc <- dplyr::collect(grab("t", as_of = "3000-01-01 00:00:00"))
  })
  withr::with_envvar(c(TZ = "US/Eastern"), {
    r_est <- dplyr::collect(grab("t", as_of = "3000-01-01 00:00:00"))
  })
  expect_equal(r_utc$x, r_est$x)
})

test_that("stow() warns when a data frame has non-default row names", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(a = 1:3)
  rownames(df) <- c("r1", "r2", "r3")
  expect_warning(stow(df, "with_rn"), "row names are not persisted")
})
