test_that("stow() accepts a fitted model and grab() round-trips it", {
  new_test_db()
  fit <- lm(mpg ~ wt, mtcars)

  stow("fit", fit)
  got <- grab("fit")

  expect_s3_class(got, "lm")
  expect_equal(coef(got), coef(fit))
})

test_that("small artifacts land in _mr_artifacts (BLOB storage)", {
  new_test_db()
  stow("a", list(k = 1, v = letters[1:3]))

  con <- .mr_get_connection()
  v <- DBI::dbGetQuery(con, "SELECT * FROM _mr_versions WHERE logical_name = 'a'")
  expect_equal(v$kind, "artifact")
  expect_equal(v$storage_location, "blob")

  blobs <- DBI::dbGetQuery(con, "SELECT physical_name FROM _mr_artifacts")
  expect_true(v$physical_name[1] %in% blobs$physical_name)
})

test_that("large artifacts land on disk when they exceed blob_threshold", {
  new_test_db()
  # Force everything to spill to disk by setting the threshold very low.
  withr::local_options(list(modelrunnR.blob_threshold = 16L))

  big <- runif(50)
  stow("big", big)

  con <- .mr_get_connection()
  v <- DBI::dbGetQuery(con, "SELECT * FROM _mr_versions WHERE logical_name = 'big'")
  expect_equal(v$storage_location, "file")
  expect_true(file.exists(v$physical_name[1]))

  got <- grab("big")
  expect_equal(got, big)
})

test_that("blob_threshold option controls the storage choice", {
  new_test_db()
  # Very high threshold: everything BLOB.
  withr::local_options(list(modelrunnR.blob_threshold = 100L * 1024L * 1024L))
  stow("small", list(1, 2, 3))

  con <- .mr_get_connection()
  v <- DBI::dbGetQuery(con, "SELECT storage_location FROM _mr_versions WHERE logical_name = 'small'")
  expect_equal(v$storage_location, "blob")
})

test_that("namespace collision between a table and an artifact errors cleanly", {
  new_test_db()
  stow("x", data.frame(n = 1:3))
  expect_error(stow("x", list(a = 1)), regexp = "already exists.*table|different kind")

  new_test_db()
  stow("y", list(a = 1))
  expect_error(stow("y", data.frame(n = 1:3)), regexp = "already exists.*artifact|different kind")
})

test_that("artifacts are recorded in run outputs and addressable via from_run", {
  new_test_db()
  s <- write_script(c(
    "stow('tbl', data.frame(n = 1:3))",
    "stow('fit', lm(n ~ 1, data.frame(n = 1:3)))"
  ))
  run <- launch(s)

  con <- .mr_get_connection()
  outs <- jsonlite::fromJSON(
    DBI::dbGetQuery(con, "SELECT outputs FROM _mr_runs WHERE run_id = ?",
                    params = list(run$run_id))$outputs[1],
    simplifyVector = FALSE
  )
  names_produced <- vapply(outs, function(p) p$name, character(1))
  expect_setequal(names_produced, c("tbl", "fit"))

  refit <- grab("fit", from_run = run$run_id)
  expect_s3_class(refit, "lm")
})
