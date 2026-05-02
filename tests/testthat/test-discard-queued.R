test_that("discard_queued() removes only queued rows", {
  new_test_db()
  con <- .mr_get_connection()

  launch({ stow(data.frame(x = 1), "metrics") }, label = "lm")
  queue({ stow(data.frame(x = 2), "metrics") }, label = "queued_a")
  queue({ stow(data.frame(x = 3), "metrics") }, label = "queued_b")

  before <- DBI::dbGetQuery(con, "SELECT status, COUNT(*) AS n FROM _mr_runs GROUP BY status")
  expect_setequal(before$status, c("success", "queued"))

  res <- discard_queued()
  expect_identical(res$n_runs, 2L)

  after <- DBI::dbGetQuery(con, "SELECT status, COUNT(*) AS n FROM _mr_runs GROUP BY status")
  expect_identical(after$status, "success")
  expect_equal(as.integer(after$n), 1L)
})

test_that("discard_queued(dry_run=TRUE) reports without deleting", {
  new_test_db()
  con <- .mr_get_connection()

  queue({ stow(data.frame(x = 1), "metrics") }, label = "a")
  queue({ stow(data.frame(x = 2), "metrics") }, label = "b")

  res <- discard_queued(dry_run = TRUE)
  expect_identical(res$n_runs, 2L)

  remaining <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs WHERE status = 'queued'")
  expect_equal(as.integer(remaining$n), 2L)
})

test_that("discard_queued(variant_label=...) filters", {
  new_test_db()
  con <- .mr_get_connection()

  queue({ stow(data.frame(x = 1), "metrics") }, label = "keep_me")
  queue({ stow(data.frame(x = 2), "metrics") }, label = "drop_me")

  res <- discard_queued(variant_label = "drop_me")
  expect_identical(res$n_runs, 1L)

  remaining <- DBI::dbGetQuery(con,
    "SELECT variant_label FROM _mr_runs WHERE status = 'queued'")
  expect_identical(remaining$variant_label, "keep_me")
})
