## Helpers for introspecting the versioning tables in tests.
mr_versions_rows <- function(name = NULL) {
  con <- .mr_get_connection()
  if (is.null(name)) {
    DBI::dbGetQuery(con, "SELECT * FROM _mr_versions ORDER BY first_seen")
  } else {
    DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? ORDER BY first_seen",
      params = list(name)
    )
  }
}

physical_tables <- function(pattern = "__") {
  con <- .mr_get_connection()
  tbls <- .mr_list_tables(con)
  grep(pattern, tbls, value = TRUE, fixed = TRUE)
}

test_that("stowing the same frame twice yields one physical table and one version row", {
  new_test_db()
  df <- data.frame(x = 1:5, y = letters[1:5], stringsAsFactors = FALSE)
  stow("t", df)
  Sys.sleep(0.01)
  stow("t", df)

  vrows <- mr_versions_rows("t")
  expect_equal(nrow(vrows), 1L)
  expect_equal(vrows$kind, "table")
  expect_true(vrows$last_seen >= vrows$first_seen)

  # Exactly one hash-suffixed physical table for "t".
  pt <- physical_tables()
  expect_equal(length(grep("^t__", pt)), 1L)
})

test_that("stowing a modified frame yields a second physical table and version row", {
  new_test_db()
  stow("t", data.frame(x = 1:3))
  stow("t", data.frame(x = c(1L, 2L, 9L)))

  vrows <- mr_versions_rows("t")
  expect_equal(nrow(vrows), 2L)
  expect_false(identical(vrows$content_hash[1], vrows$content_hash[2]))

  pt <- physical_tables()
  expect_equal(length(grep("^t__", pt)), 2L)

  # Default grab returns the most recent version (by first_seen).
  latest <- grab("t")
  expect_equal(latest$x, c(1L, 2L, 9L))
})

test_that("hash is stable across row and column reorderings", {
  new_test_db()
  df1 <- data.frame(a = 1:3, b = c("x", "y", "z"), stringsAsFactors = FALSE)
  df2 <- df1[c(3, 1, 2), c("b", "a")]
  rownames(df2) <- NULL

  stow("ordered", df1)
  stow("ordered", df2)

  vrows <- mr_versions_rows("ordered")
  expect_equal(nrow(vrows), 1L)  # row and column reorderings do NOT produce a new version
})

test_that("grab(version = h) returns exactly that hash's frame", {
  new_test_db()
  stow("t", data.frame(x = 1:2))
  stow("t", data.frame(x = c(10L, 20L)))

  vrows <- mr_versions_rows("t")
  expect_equal(nrow(vrows), 2L)

  older <- vrows$content_hash[1]
  newer <- vrows$content_hash[2]

  expect_equal(grab("t", version = older)$x, 1:2)
  expect_equal(grab("t", version = newer)$x, c(10L, 20L))
  expect_equal(grab("t")$x, c(10L, 20L))
})

test_that("grab(from_run = rid) returns what that run produced", {
  new_test_db()

  script <- write_script(c(
    "v <- get0('v', envir = globalenv(), ifnotfound = 1L)",
    "stow('seq', data.frame(x = seq_len(v)))"
  ))

  r1 <- launch(script); assign("v", 2L, envir = globalenv())
  r2 <- launch(script); assign("v", 3L, envir = globalenv())
  r3 <- launch(script)

  on.exit(rm("v", envir = globalenv()), add = TRUE)

  expect_equal(grab("seq", from_run = r1$run_id)$x, 1L)
  expect_equal(grab("seq", from_run = r2$run_id)$x, 1:2)
  expect_equal(grab("seq", from_run = r3$run_id)$x, 1:3)
})

test_that("grab(as_of = ts) returns the version latest at that time", {
  new_test_db()
  stow("t", data.frame(x = 1L))
  t1 <- Sys.time()
  Sys.sleep(0.05)
  stow("t", data.frame(x = 2L))
  Sys.sleep(0.05)
  t2 <- Sys.time()
  stow("t", data.frame(x = 3L))

  expect_equal(grab("t", as_of = t1)$x, 1L)
  expect_equal(grab("t", as_of = t2)$x, 2L)
  expect_equal(grab("t")$x, 3L)
})

test_that("grab() errors cleanly when a name has never been stowed", {
  new_test_db()
  expect_error(grab("ghost"), "no value stowed")
})

test_that("grab(version = ...) errors cleanly when the hash is unknown", {
  new_test_db()
  stow("t", data.frame(x = 1))
  expect_error(grab("t", version = "deadbeef"), "version")
})
