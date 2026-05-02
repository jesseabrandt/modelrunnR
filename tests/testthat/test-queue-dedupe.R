test_that("queue() dedupes identical inline calls", {
  new_test_db()
  con <- modelrunnR:::.mr_get_connection()

  r1 <- queue({ x <- 1 + 1 })
  r2 <- queue({ x <- 1 + 1 })

  expect_equal(r1$run_id, r2$run_id)
  total <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n
  expect_equal(as.integer(total), 1L)
})

test_that("queue() differentiates by variant_label", {
  new_test_db()
  con <- modelrunnR:::.mr_get_connection()

  r1 <- queue({ x <- 1 }, label = "a")
  r2 <- queue({ x <- 1 }, label = "b")

  expect_false(identical(r1$run_id, r2$run_id))
  total <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n
  expect_equal(as.integer(total), 2L)
})

test_that("queue() differentiates by rebind values", {
  new_test_db()
  con <- modelrunnR:::.mr_get_connection()

  r1 <- queue({ y <- grab("k") }, rebind = list(k = 1L))
  r2 <- queue({ y <- grab("k") }, rebind = list(k = 2L))

  expect_false(identical(r1$run_id, r2$run_id))
  total <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs WHERE status = 'queued'")$n
  expect_equal(as.integer(total), 2L)
})

test_that("queue() does NOT dedupe against a successful run (preserves explicit re-stage contract)", {
  new_test_db()
  con <- modelrunnR:::.mr_get_connection()

  launched <- launch({ stow(data.frame(v = 1), "metrics") }, label = "lm")
  expect_equal(launched$status, "success")

  qd <- queue({ stow(data.frame(v = 1), "metrics") }, label = "lm")
  expect_false(identical(qd$run_id, launched$run_id))
  expect_equal(qd$status, "queued")
})

test_that("queue() batch dedupes per envelope", {
  new_test_db()
  con <- modelrunnR:::.mr_get_connection()

  # First batch: writes 3 queued rows.
  b1 <- queue({ y <- grab("k") }, rebind = mr_binds(k = 1:3))
  expect_equal(nrow(b1), 3L)

  # Second batch: identical envelopes; should dedupe to the same 3 rows.
  b2 <- queue({ y <- grab("k") }, rebind = mr_binds(k = 1:3))
  expect_equal(nrow(b2), 3L)
  expect_setequal(b2$run_id, b1$run_id)

  total <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n
  expect_equal(as.integer(total), 3L)
})
