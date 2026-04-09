## Helper for writing a multi-file script bundle to a test-local tempdir.
write_bundle <- function(files, envir = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = envir)
  paths <- vapply(names(files), function(n) {
    p <- file.path(dir, n)
    writeLines(files[[n]], p)
    p
  }, character(1))
  as.list(setNames(paths, names(files)))
}

get_code_hash <- function(run_id) {
  con <- .mr_get_connection()
  DBI::dbGetQuery(
    con,
    "SELECT code_hash FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )$code_hash[1]
}

test_that("a script with no helpers records a non-NA code_hash", {
  new_test_db()
  s <- write_script("stow('x', data.frame(n = 1))")
  run <- launch(s)
  expect_true(nzchar(get_code_hash(run$run_id)))
})

test_that("editing the script changes code_hash", {
  new_test_db()
  dir <- withr::local_tempdir()
  s <- file.path(dir, "step.R")
  writeLines("stow('x', data.frame(n = 1))", s)
  r1 <- launch(s)

  writeLines(c(
    "stow('x', data.frame(n = 2))",
    "# an added comment also changes bytes"
  ), s)
  r2 <- launch(s)

  expect_false(identical(get_code_hash(r1$run_id), get_code_hash(r2$run_id)))
})

test_that("editing a sourced helper changes code_hash", {
  new_test_db()
  b <- write_bundle(list(
    "helper.R" = "mkdf <- function() data.frame(n = 1)",
    "step.R"   = ""
  ))
  step_code <- sprintf(
    "source('%s'); stow('out', mkdf())", b$helper.R
  )
  writeLines(step_code, b$step.R)
  r1 <- launch(b$step.R)

  # Change the helper — script bytes unchanged, but code_hash must move.
  writeLines("mkdf <- function() data.frame(n = 99L)", b$helper.R)
  r2 <- launch(b$step.R)

  expect_false(identical(get_code_hash(r1$run_id), get_code_hash(r2$run_id)))
})

test_that("transitive helpers contribute to code_hash", {
  new_test_db()
  b <- write_bundle(list(
    "a.R" = "library(stats)",  # placeholder; content doesn't matter for the hash
    "b.R" = "",                # will be edited below
    "step.R" = ""              # filled in after we know b$b.R's path
  ))
  writeLines(sprintf("source('%s')", b$b.R), b$a.R)
  writeLines("x <- 1",          b$b.R)
  writeLines(sprintf(
    "source('%s'); stow('out', data.frame(x = x))", b$a.R
  ), b$step.R)

  r1 <- launch(b$step.R)

  # Only edit the transitive helper b.R; step and a.R are untouched.
  writeLines("x <- 999",        b$b.R)
  r2 <- launch(b$step.R)

  expect_false(identical(get_code_hash(r1$run_id), get_code_hash(r2$run_id)))
})

test_that("CRLF vs LF line endings produce the same code_hash", {
  new_test_db()
  dir <- withr::local_tempdir()
  s_lf   <- file.path(dir, "step_lf.R")
  s_crlf <- file.path(dir, "step_crlf.R")

  # Write the same logical content with different EOL conventions.
  body <- c("stow('x', data.frame(n = 1))", "")
  writeBin(charToRaw(paste(body, collapse = "\n")),   s_lf)
  writeBin(charToRaw(paste(body, collapse = "\r\n")), s_crlf)

  r1 <- launch(s_lf)
  r2 <- launch(s_crlf)

  expect_identical(get_code_hash(r1$run_id), get_code_hash(r2$run_id))
})

test_that("cyclic sourcing does not infinite-loop and still records code_hash", {
  new_test_db()
  b <- write_bundle(list(
    "a.R"    = "",
    "step.R" = ""
  ))
  # a.R sources itself. Without cycle detection this would recurse forever.
  writeLines(sprintf("source('%s')", b$a.R), b$a.R)
  writeLines(sprintf(
    "source('%s'); stow('out', data.frame(n = 1))", b$a.R
  ), b$step.R)

  expect_no_error(run <- launch(b$step.R))
  expect_true(nzchar(get_code_hash(run$run_id)))
})
