read_external_inputs <- function(run_id) {
  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT external_inputs FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  jsonlite::fromJSON(row$external_inputs[1], simplifyVector = FALSE)
}

test_that("declared env vars are hashed and stored on the run row", {
  new_test_db()
  withr::local_envvar(list(MR_TEST_TOKEN = "first"))
  s <- write_script("stow('x', data.frame(n = 1))")

  r1 <- launch(s, external_inputs = list(env = "MR_TEST_TOKEN"))
  ext1 <- read_external_inputs(r1$run_id)
  expect_length(ext1$env, 1L)
  expect_equal(ext1$env[[1]]$name, "MR_TEST_TOKEN")
  first_hash <- ext1$env[[1]]$hash
  expect_true(nzchar(first_hash))

  withr::local_envvar(list(MR_TEST_TOKEN = "second"))
  r2 <- launch(s, external_inputs = list(env = "MR_TEST_TOKEN"))
  ext2 <- read_external_inputs(r2$run_id)
  expect_false(identical(first_hash, ext2$env[[1]]$hash))
})

test_that("declared files are hashed and stored", {
  new_test_db()
  dir <- withr::local_tempdir()
  data_path <- file.path(dir, "config.json")
  writeLines('{"a": 1}', data_path)

  s <- write_script("stow('x', data.frame(n = 1))")
  r <- launch(s, external_inputs = list(files = data_path))

  ext <- read_external_inputs(r$run_id)
  expect_length(ext$files, 1L)
  expect_equal(normalizePath(ext$files[[1]]$path), normalizePath(data_path))
  expect_true(nzchar(ext$files[[1]]$hash))
})

test_that("a missing declared file errors before the run is written", {
  new_test_db()
  s <- write_script("stow('x', data.frame(n = 1))")

  before <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  expect_error(
    launch(s, external_inputs = list(files = "/nope/does-not-exist.txt")),
    regexp = "not found|does not exist"
  )
  after <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  expect_equal(after, before)
})
