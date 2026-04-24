## Helper: stow N distinct artifact versions of a name so there are
## Shape A rows in _mr_versions to prune. Used by the non-skipped tests below.
## Data-frame stow now goes to Shape B (append log), not _mr_versions, so
## prune_versions() on data-frame names no longer applies.
stow_n_artifact_versions <- function(name, n) {
  for (i in seq_len(n)) {
    stow(list(i = i), name)
  }
}

# Deleted: 11 prune_versions() tests for data-frame-stowed names —
# Shape B (append log) does not use _mr_versions; prune_versions() operates
# on _mr_versions (Shape A) only. Coverage for artifact pruning is in the
# remaining tests below.

test_that("prune_versions() errors when both keep_latest and keep are set", {
  new_test_db()
  stow_n_artifact_versions("t", 3)
  expect_error(
    prune_versions("t", keep_latest = TRUE, keep = 2),
    "either .keep_latest. or .keep."
  )
})

test_that("prune removes filesystem artifact files when storage = 'file'", {
  new_test_db()
  withr::local_options(list(modelrunnR.blob_threshold = 16L))

  # Two disk-resident artifacts.
  stow(runif(50), "a")
  stow(runif(60), "a")  # different hash

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

test_that("empty modelrunnR_artifacts/ dir is removed after a full-prune", {
  new_test_db()
  withr::local_options(list(modelrunnR.blob_threshold = 16L))

  # Stow one disk-resident artifact so the dir gets created.
  stow(runif(50), "a")
  artifact_dir <- file.path(dirname(db_path()), "modelrunnR_artifacts")
  expect_true(dir.exists(artifact_dir))

  # Prune it; the dir should now be empty and then removed.
  prune_versions("a", keep = 0, force = TRUE)
  expect_false(dir.exists(artifact_dir))
})
