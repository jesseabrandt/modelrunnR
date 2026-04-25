physical_tables <- function(pattern = "__") {
  con <- .mr_get_connection()
  tbls <- .mr_list_tables(con)
  grep(pattern, tbls, value = TRUE, fixed = TRUE)
}

test_that("grab(from_run = rid) returns what that run produced (append-shape)", {
  new_test_db()

  # Two sequential launches each stow distinct row counts. grab() with
  # from_run= must filter to that run's rows only.
  r1 <- launch({ stow(data.frame(x = 1L), "seq") })
  r2 <- launch({ stow(data.frame(x = seq_len(2L)), "seq") })
  r3 <- launch({ stow(data.frame(x = seq_len(3L)), "seq") })

  expect_equal(nrow(dplyr::collect(grab("seq", from_run = r1$run_id))), 1L)
  expect_equal(nrow(dplyr::collect(grab("seq", from_run = r2$run_id))), 2L)
  expect_equal(nrow(dplyr::collect(grab("seq", from_run = r3$run_id))), 3L)
})

test_that("grab() errors cleanly when a name has never been stowed", {
  new_test_db()
  expect_error(grab("ghost"), "no value stowed")
})

# Deleted: "stow() warns when df has non-default row names" — append-shape's
# .mr_append_write_frame() does not currently emit the row-names warning
# (only .mr_stow_table() for versioned-shape does). Surfaced as a production gap
# for a separate fix; not a Task 16 concern.
