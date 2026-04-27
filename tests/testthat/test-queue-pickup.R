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

test_that("rebinds survive the queue -> launch(mr_run(id)) round trip and apply at pickup", {
  withr::with_tempdir({
    new_test_db()
    # Queue a body that returns the rebound value, with a literal rebind.
    q <- queue(
      { y <- grab("alpha"); stow(data.frame(value = y), "out") },
      rebind = list(alpha = 0.42)
    )
    expect_equal(q$status, "queued")
    # Pick up — body executes with the staged rebind.
    r <- launch(mr_run(q$run_id))
    expect_equal(r$status, "success")
    # The stowed value should be the rebound 0.42, not whatever a bare
    # grab("alpha") would have resolved to (which would error since
    # nothing's stowed under "alpha" in this fresh db).
    out <- grab("out") |> dplyr::collect()
    # `out` is a single-row, single-column tibble holding 0.42.
    expect_equal(out$value[[1]], 0.42)
  })
})

test_that("queued-row pickup that would be skipped_fresh sets the row's status to skipped_fresh in place", {
  withr::with_tempdir({
    new_test_db()
    # First, run the same expression to success so a fresh prior exists.
    r1 <- launch({ x <- 1 + 1; stow(x, "two") })
    # Now queue an identical body.
    q  <- queue({ x <- 1 + 1; stow(x, "two") })
    # Pickup: should see the freshness check, skip, and stamp the
    # queued row as skipped_fresh — not execute, not error.
    r2 <- launch(mr_run(q$run_id))
    expect_equal(r2$run_id, q$run_id)
    expect_equal(r2$status, "skipped_fresh")
  })
})

test_that("file-step queued pickup re-sources from disk and warns when content drifted", {
  withr::with_tempdir({
    new_test_db()
    writeLines("x <- 'before'; stow(x, 'g')", "fit.R")
    q <- queue("fit.R")
    writeLines("x <- 'after';  stow(x, 'g')", "fit.R")  # edit
    expect_warning(launch(mr_run(q$run_id)), "drifted")
    # Refreshed columns reflect the executed (new) bytes.
    con <- modelrunnR:::.mr_get_connection()
    post <- DBI::dbGetQuery(con,
      "SELECT code_body, code_hash, status FROM _mr_runs WHERE run_id = ?",
      params = list(q$run_id))
    expect_match(post$code_body, "after", fixed = TRUE)
    expect_equal(post$status, "success")
  })
})

test_that("file-step queued pickup with no drift does not warn", {
  withr::with_tempdir({
    new_test_db()
    writeLines("x <- 'stable'; stow(x, 'g')", "fit.R")
    q <- queue("fit.R")
    expect_no_warning(launch(mr_run(q$run_id)))
  })
})

test_that("file-step queued pickup falls back to the snapshot when the file is gone", {
  withr::with_tempdir({
    new_test_db()
    writeLines("x <- 'snap'; stow(x, 'g')", "fit.R")
    q <- queue("fit.R")
    file.remove("fit.R")
    expect_message(launch(mr_run(q$run_id)), "is gone from disk")
    con <- modelrunnR:::.mr_get_connection()
    post <- DBI::dbGetQuery(con, "SELECT status FROM _mr_runs WHERE run_id = ?",
                            params = list(q$run_id))
    expect_equal(post$status, "success")
  })
})
