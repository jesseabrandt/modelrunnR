test_that("a never-run step is stale with reason 'never_run'", {
  new_test_db()
  s <- write_script("stow('x', data.frame(n = 1))")
  result <- .mr_is_stale(normalizePath(s))
  expect_true(result$stale)
  expect_equal(result$reasons, "never_run")
})

test_that("re-running an unchanged step with unchanged inputs is fresh", {
  new_test_db()
  writer <- write_script("stow('x', data.frame(n = 1))")
  launch(writer)

  reader <- write_script(c(
    "x <- grab('x')",
    "stow('y', x)"
  ))
  launch(reader)

  result <- .mr_is_stale(normalizePath(reader))
  expect_false(result$stale)
  expect_length(result$reasons, 0L)
})

test_that("editing the script marks it stale with reason 'code'", {
  new_test_db()
  dir <- withr::local_tempdir()
  s <- file.path(dir, "step.R")
  writeLines("stow('x', data.frame(n = 1))", s)
  launch(s)

  writeLines(c("# touched", "stow('x', data.frame(n = 1))"), s)
  result <- .mr_is_stale(normalizePath(s))
  expect_true(result$stale)
  expect_true("code" %in% result$reasons)
})

test_that("touching a helper marks the step stale with reason 'code'", {
  new_test_db()
  dir <- withr::local_tempdir()
  helper <- file.path(dir, "helper.R")
  step   <- file.path(dir, "step.R")
  writeLines("mk <- function() data.frame(n = 1)", helper)
  writeLines(sprintf("source('%s'); stow('x', mk())", helper), step)
  launch(step)

  writeLines("mk <- function() data.frame(n = 99)", helper)
  result <- .mr_is_stale(normalizePath(step))
  expect_true(result$stale)
  expect_true("code" %in% result$reasons)
})

test_that("a changed input produces 'input:<name>' staleness downstream", {
  new_test_db()
  writer <- write_script("stow('x', data.frame(n = 1))")
  launch(writer)

  reader <- write_script(c(
    "x <- grab('x')",
    "stow('y', x)"
  ))
  launch(reader)

  # Re-run the writer with different content → new hash for x.
  writer2 <- write_script("stow('x', data.frame(n = 999))")
  launch(writer2)

  # reader is now stale because its recorded input x has a newer hash.
  result <- .mr_is_stale(normalizePath(reader))
  expect_true(result$stale)
  expect_true(any(grepl("^input:x$", result$reasons)))
})

test_that("touching a declared external file produces 'external:...' staleness", {
  new_test_db()
  dir <- withr::local_tempdir()
  cfg <- file.path(dir, "cfg.txt")
  writeLines("v1", cfg)

  s <- write_script("stow('x', data.frame(n = 1))")
  launch(s, external_inputs = list(files = cfg))

  result1 <- .mr_is_stale(normalizePath(s))
  expect_false(result1$stale)

  writeLines("v2", cfg)
  result2 <- .mr_is_stale(normalizePath(s))
  expect_true(result2$stale)
  expect_true(any(grepl("^external:", result2$reasons)))
})
