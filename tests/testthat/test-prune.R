## Helper: stow N distinct artifact versions of a name so there are
## versioned-shape rows in _mr_versions to prune.
## Data-frame stow now goes to append-shape (append log), not _mr_versions, so
## prune(..., by = "version") on data-frame names no longer applies.
stow_n_artifact_versions <- function(name, n) {
  for (i in seq_len(n)) {
    stow(list(i = i), name)
  }
}

test_that("prune() errors when both keep_latest and keep are set", {
  new_test_db()
  stow_n_artifact_versions("t", 3)
  expect_error(
    prune("t", keep_latest = TRUE, keep = 2),
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

  prune("a", keep = 1, force = TRUE)

  v2 <- DBI::dbGetQuery(con, "SELECT physical_name FROM _mr_versions WHERE logical_name = 'a'")
  expect_equal(nrow(v2), 1L)
  pruned_files <- setdiff(v$physical_name, v2$physical_name)
  expect_false(any(file.exists(pruned_files)))
  expect_true(file.exists(v2$physical_name))
})

test_that("empty modelrunnR_artifacts/ dir is removed after a full-prune", {
  new_test_db()
  withr::local_options(list(modelrunnR.blob_threshold = 16L))

  stow(runif(50), "a")
  artifact_dir <- file.path(dirname(db_path()), "modelrunnR_artifacts")
  expect_true(dir.exists(artifact_dir))

  prune("a", keep = 0, force = TRUE)
  expect_false(dir.exists(artifact_dir))
})

test_that("prune() auto-dispatches: versioned-shape name routes to version pruning", {
  new_test_db()
  stow_n_artifact_versions("t", 3)
  # by = "auto" is the default
  prune("t", keep = 1, force = TRUE)
  con <- .mr_get_connection()
  v <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS c FROM _mr_versions WHERE logical_name = 't'")
  expect_equal(v$c[1], 1)
})

test_that("prune() errors when by='run' on a versioned-shape name", {
  new_test_db()
  stow_n_artifact_versions("t", 2)
  expect_error(
    prune("t", by = "run", keep = 0, force = TRUE),
    "versioned"
  )
})

test_that("prune() errors when by='version' on a append-shape name", {
  new_test_db()
  launch({ stow(data.frame(m = "lm"), "metrics") }, label = "lm")
  expect_error(
    prune("metrics", by = "version", keep = 0, force = TRUE),
    "append table"
  )
})
