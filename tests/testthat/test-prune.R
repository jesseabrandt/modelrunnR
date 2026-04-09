## Helper: stow N distinct versions of a name via tracked writers so
## there are no spurious interactive-write rows in the way.
stow_n_versions <- function(name, n) {
  for (i in seq_len(n)) {
    w <- write_script(sprintf(
      "stow('%s', data.frame(i = %dL))", name, i
    ))
    launch(w)
  }
}

test_that("version-count threshold emits a warning after writing", {
  new_test_db()
  withr::local_options(list(modelrunnR.version_warn_threshold = 3))

  # First 3 writes must not warn.
  stow_n_versions("t", 3)
  expect_equal(nrow(versions("t")), 3L)

  # The 4th write must warn.
  expect_warning(
    launch(write_script("stow('t', data.frame(i = 99L))")),
    regexp = "prune_versions|versions"
  )
})

test_that("prune_versions(name, keep = N) leaves N most recent versions", {
  new_test_db()
  stow_n_versions("t", 5)
  expect_equal(nrow(versions("t")), 5L)

  pruned <- prune_versions("t", keep = 2, force = TRUE)
  expect_equal(nrow(versions("t")), 2L)
  # The physical tables for the pruned 3 are gone.
  con <- .mr_get_connection()
  remaining_phys <- grep("^t__", .mr_list_tables(con), value = TRUE)
  expect_equal(length(remaining_phys), 2L)
})

test_that("versions referenced by runs are protected unless force = TRUE", {
  new_test_db()
  stow_n_versions("t", 3)

  # Without force, keep=1 tries to prune 2 older versions but both are
  # referenced by run rows → the prune is a no-op with a warning.
  expect_warning(
    prune_versions("t", keep = 1),
    regexp = "protected|referenced"
  )
  expect_equal(nrow(versions("t")), 3L)

  # With force, protection is bypassed.
  prune_versions("t", keep = 1, force = TRUE)
  expect_equal(nrow(versions("t")), 1L)
})

test_that("grab(from_run = ...) errors clearly after the pinned version is pruned", {
  new_test_db()
  r1 <- launch(write_script("stow('t', data.frame(n = 1))"))
  r2 <- launch(write_script("stow('t', data.frame(n = 2))"))

  prune_versions("t", keep = 1, force = TRUE)
  expect_error(grab("t", from_run = r1$run_id), regexp = "not found|pruned")
})

test_that("keep_latest = TRUE leaves only the current view target per name", {
  new_test_db()
  stow_n_versions("t", 4)
  prune_versions("t", keep_latest = TRUE, force = TRUE)
  v <- versions("t")
  expect_equal(nrow(v), 1L)
  # The surviving row is the one with the largest first_seen.
})

test_that("older_than prunes by first_seen age", {
  new_test_db()
  launch(write_script("stow('t', data.frame(n = 1))"))

  # Force the existing row's first_seen into the past so it's older
  # than the threshold.
  con <- .mr_get_connection()
  DBI::dbExecute(
    con,
    "UPDATE _mr_versions SET first_seen = first_seen - INTERVAL 10 DAY
      WHERE logical_name = 't'"
  )

  launch(write_script("stow('t', data.frame(n = 2))"))
  expect_equal(nrow(versions("t")), 2L)

  prune_versions("t", older_than = "5d", force = TRUE)
  v <- versions("t")
  expect_equal(nrow(v), 1L)
})

test_that("prune removes filesystem artifact files when storage = 'file'", {
  new_test_db()
  withr::local_options(list(modelrunnR.blob_threshold = 16L))

  # Two disk-resident artifacts.
  stow("a", runif(50))
  stow("a", runif(60))  # different hash

  con <- .mr_get_connection()
  v <- DBI::dbGetQuery(con, "SELECT physical_name FROM _mr_versions WHERE logical_name = 'a'")
  expect_equal(nrow(v), 2L)
  expect_true(all(file.exists(v$physical_name)))

  prune_versions("a", keep = 1, force = TRUE)

  v2 <- DBI::dbGetQuery(con, "SELECT physical_name FROM _mr_versions WHERE logical_name = 'a'")
  expect_equal(nrow(v2), 1L)
  # The file for the pruned artifact is gone; the surviving file is still present.
  pruned_files <- setdiff(v$physical_name, v2$physical_name)
  expect_false(any(file.exists(pruned_files)))
  expect_true(file.exists(v2$physical_name))
})
