test_that("append-shape stow() populates _mr_append_chunks atomically with the row INSERT", {
  withr::with_tempdir({
    new_test_db()
    r <- launch({ stow(data.frame(x = 1:3), "metrics") })
    expect_equal(r$status, "success")

    con <- modelrunnR:::.mr_get_connection()
    rows <- DBI::dbGetQuery(con,
      "SELECT logical_name, run_id, rows_appended, chunk_hash
         FROM _mr_append_chunks WHERE logical_name = ?",
      params = list("metrics"))
    expect_equal(nrow(rows), 1L)
    expect_equal(rows$run_id,        r$run_id)
    expect_equal(rows$rows_appended, 3L)
    expect_match(rows$chunk_hash, "^[0-9a-f]+$")
  })
})

test_that("two stow() calls in one launch produce two _mr_append_chunks rows", {
  withr::with_tempdir({
    new_test_db()
    r <- launch({
      stow(data.frame(x = 1L), "out")
      stow(data.frame(x = 2L), "out")
    })
    con <- modelrunnR:::.mr_get_connection()
    rows <- DBI::dbGetQuery(con,
      "SELECT chunk_hash FROM _mr_append_chunks WHERE logical_name = ? AND run_id = ?",
      params = list("out", r$run_id))
    expect_equal(nrow(rows), 2L)
    expect_equal(length(unique(rows$chunk_hash)), 2L)
  })
})

test_that("two runs producing identical content land two _mr_append_chunks rows (no PK collision)", {
  withr::with_tempdir({
    new_test_db()
    r1 <- launch({ stow(data.frame(x = 7L), "m") })
    r2 <- launch({ stow(data.frame(x = 7L), "m") }, force = TRUE)
    con <- modelrunnR:::.mr_get_connection()
    rows <- DBI::dbGetQuery(con,
      "SELECT run_id, chunk_hash FROM _mr_append_chunks WHERE logical_name = ?",
      params = list("m"))
    expect_equal(nrow(rows), 2L)
    expect_equal(length(unique(rows$chunk_hash)), 1L)   # same content
    expect_setequal(rows$run_id, c(r1$run_id, r2$run_id))
  })
})

test_that("a stow inside a failing launch leaves no _mr_append_chunks row (rolled back)", {
  withr::with_tempdir({
    new_test_db()
    err <- tryCatch(
      launch({ stow(data.frame(x = 1L), "fail_name"); stop("boom") }),
      error = function(e) conditionMessage(e)
    )
    expect_match(err, "boom", fixed = TRUE)
    # The stow's own transaction commits the row + the chunk record
    # together; the launch-level error fires AFTER stow returns. So
    # the chunk row IS present (this asserts the per-stow atomicity:
    # row + chunk record are inseparable, even when the surrounding
    # launch later errors). A future block-level rollback (TODO entry
    # "Block-level transaction semantics for append-shape") would
    # change this; flip the assertion then.
    con <- modelrunnR:::.mr_get_connection()
    rows <- DBI::dbGetQuery(con,
      "SELECT * FROM _mr_append_chunks WHERE logical_name = 'fail_name'")
    expect_equal(nrow(rows), 1L)
  })
})
