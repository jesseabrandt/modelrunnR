test_that("launch(mr_run(id)) on a queued row updates the same row in place", {
  withr::with_tempdir({
    new_test_db()
    q <- queue({ x <- 21 + 21; stow(x, "answer") })
    r <- launch(mr_run(q$run_id))
    expect_equal(r$run_id, q$run_id)              # same id
    expect_equal(r$status, "success")             # status flipped
    expect_false(is.na(r$started_at))             # populated
    expect_false(is.na(r$duration_ms))
    con <- modelrunnR:::.mr_get_connection()
    n <- DBI::dbGetQuery(con,
      "SELECT COUNT(*) AS n FROM _mr_runs WHERE run_id = ?",
      params = list(q$run_id))$n
    expect_equal(n, 1L)                            # in-place: still one row
  })
})

test_that("queued row's frozen columns are preserved across pickup", {
  withr::with_tempdir({
    new_test_db()
    q <- queue({ y <- 7 }, label = "exp_a")
    pre  <- modelrunnR:::.mr_get_connection() |>
      DBI::dbGetQuery("SELECT step, code_body, code_hash, variant_label, rebinds FROM _mr_runs WHERE run_id = ?",
                      params = list(q$run_id))
    launch(mr_run(q$run_id))
    post <- modelrunnR:::.mr_get_connection() |>
      DBI::dbGetQuery("SELECT step, code_body, code_hash, variant_label, rebinds FROM _mr_runs WHERE run_id = ?",
                      params = list(q$run_id))
    expect_equal(pre$step,          post$step)
    expect_equal(pre$code_body,     post$code_body)
    expect_equal(pre$code_hash,     post$code_hash)
    expect_equal(pre$variant_label, post$variant_label)
    expect_equal(pre$rebinds,       post$rebinds)
  })
})

test_that("non-queued mr_run() relaunch still writes a new row (Phase 1 semantics unchanged)", {
  withr::with_tempdir({
    new_test_db()
    r1 <- launch({ x <- 1 })
    r2 <- launch(mr_run(r1$run_id))
    expect_false(r2$run_id == r1$run_id)         # new row, not in-place
  })
})
