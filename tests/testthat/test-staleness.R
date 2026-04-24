test_that("a never-run step is stale with reason 'never_run'", {
  new_test_db()
  s <- write_script("stow(data.frame(n = 1), 'x')")
  result <- .mr_is_stale(normalizePath(s))
  expect_true(result$stale)
  expect_equal(result$reasons, "never_run")
})

test_that("re-running an unchanged step with unchanged inputs is fresh", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  writer <- write_script("stow(data.frame(n = 1), 'x')")
  launch(writer)

  reader <- write_script(c(
    "x <- grab('x') |> dplyr::collect()",
    "stow(x, 'y')"
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
  writeLines("stow(data.frame(n = 1), 'x')", s)
  launch(s)

  writeLines(c("# touched", "stow(data.frame(n = 1), 'x')"), s)
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
  writeLines(sprintf("source('%s'); stow(mk(), 'x')", helper), step)
  launch(step)

  writeLines("mk <- function() data.frame(n = 99)", helper)
  result <- .mr_is_stale(normalizePath(step))
  expect_true(result$stale)
  expect_true("code" %in% result$reasons)
})

test_that("a changed input produces 'input:<name>' staleness downstream", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  writer <- write_script("stow(data.frame(n = 1), 'x')")
  launch(writer)

  reader <- write_script(c(
    "x <- grab('x') |> dplyr::collect()",
    "stow(x, 'y')"
  ))
  launch(reader)

  # Re-run the writer with different content → new hash for x.
  writer2 <- write_script("stow(data.frame(n = 999), 'x')")
  launch(writer2)

  # reader is now stale because its recorded input x has a newer hash.
  result <- .mr_is_stale(normalizePath(reader))
  expect_true(result$stale)
  expect_true(any(grepl("^input:x$", result$reasons)))
})

test_that("a declared env var that stays set is fresh on re-check", {
  new_test_db()
  withr::local_envvar(MR_TEST_VAR = "hello")

  s <- write_script("stow(data.frame(n = 1), 'x')")
  launch(s, external_inputs = list(env = "MR_TEST_VAR"))

  # Unchanged env var: second check must NOT report stale
  # (regression: JSON round-trip of the stored hash used to turn
  # NA_character_ into NULL and falsely flag the step).
  result <- .mr_is_stale(normalizePath(s))
  expect_false(any(grepl("^external:env:", result$reasons)))
})

test_that("a declared env var that was and remains unset is fresh on re-check", {
  new_test_db()
  Sys.unsetenv("MR_TEST_VAR_UNSET")

  s <- write_script("stow(data.frame(n = 1), 'x')")
  launch(s, external_inputs = list(env = "MR_TEST_VAR_UNSET"))

  result <- .mr_is_stale(normalizePath(s))
  expect_false(any(grepl("^external:env:", result$reasons)))
})

test_that("a declared env var whose value changes is stale", {
  new_test_db()
  withr::local_envvar(MR_TEST_VAR = "before")

  s <- write_script("stow(data.frame(n = 1), 'x')")
  launch(s, external_inputs = list(env = "MR_TEST_VAR"))

  Sys.setenv(MR_TEST_VAR = "after")
  result <- .mr_is_stale(normalizePath(s))
  expect_true(any(grepl("^external:env:MR_TEST_VAR$", result$reasons)))
})

test_that("touching a declared external file produces 'external:...' staleness", {
  new_test_db()
  dir <- withr::local_tempdir()
  cfg <- file.path(dir, "cfg.txt")
  writeLines("v1", cfg)

  s <- write_script("stow(data.frame(n = 1), 'x')")
  launch(s, external_inputs = list(files = cfg))

  result1 <- .mr_is_stale(normalizePath(s))
  expect_false(result1$stale)

  writeLines("v2", cfg)
  result2 <- .mr_is_stale(normalizePath(s))
  expect_true(result2$stale)
  expect_true(any(grepl("^external:", result2$reasons)))
})

test_that("per-variant staleness: two labels get independent histories", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "alpha")
  launch(s, label = "beta")

  # Both are now "fresh" against their own histories.
  expect_match(
    capture.output(launch(s, label = "alpha"), type = "message") |> paste(collapse = "\n"),
    "fresh"
  )
  expect_match(
    capture.output(launch(s, label = "beta"), type = "message") |> paste(collapse = "\n"),
    "fresh"
  )
})

test_that("editing the script invalidates all variants via code_hash", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "alpha")

  writeLines(c('x <- 1', 'stow(data.frame(a = 1), "out")'), s)

  out <- capture.output(launch(s, label = "alpha"), type = "message") |>
         paste(collapse = "\n")
  expect_match(out, "stale")
  expect_match(out, "code")
})
