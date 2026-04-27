test_that("queue({ ... }) writes one row to _mr_runs with status='queued'", {
  new_test_db()

  r <- queue({ x <- 1 + 1 })
  expect_s3_class(r, "data.frame")
  expect_equal(nrow(r), 1L)
  expect_equal(r$status, "queued")
  expect_true(nzchar(r$run_id))
  expect_match(r$step, "^<inline:")
})

test_that("queue() returns invisibly", {
  new_test_db()

  result <- withVisible(queue({ x <- 1 }))
  expect_false(result$visible)
})

test_that("queued row's code_body matches the deparsed expression", {
  new_test_db()

  r <- queue({ z <- 42 })
  con <- modelrunnR:::.mr_get_connection()
  stored <- DBI::dbGetQuery(con, "SELECT code_body FROM _mr_runs WHERE run_id = ?",
                            params = list(r$run_id))$code_body[1]
  expect_match(stored, "z <- 42", fixed = TRUE)
})

test_that("queued row's execution columns are NA", {
  new_test_db()

  r <- queue({ x <- 1 })
  con <- modelrunnR:::.mr_get_connection()
  row <- DBI::dbGetQuery(con,
    "SELECT inputs, outputs, started_at, duration_ms, hostname, helpers, external_inputs, git_sha
       FROM _mr_runs WHERE run_id = ?",
    params = list(r$run_id))
  # JSON columns: empty array/object sentinel, not NA, matches launch() conventions
  expect_equal(row$inputs[1], "[]")
  expect_equal(row$outputs[1], "[]")
  # external_inputs serializes as {"files":[],"env":[]} (a JSON object, not [])
  ext <- jsonlite::fromJSON(row$external_inputs[1], simplifyVector = FALSE)
  expect_length(ext$files, 0L)
  expect_length(ext$env, 0L)
  expect_equal(row$helpers[1], "[]")
  # Timing + session-context: NA at queue time.
  expect_true(is.na(row$started_at[1]))
  expect_true(is.na(row$duration_ms[1]))
  expect_true(is.na(row$hostname[1]))
  expect_true(is.na(row$git_sha[1]))
})
