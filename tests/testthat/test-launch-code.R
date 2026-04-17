test_that("launch_code() round-trips an inline launch's code body", {
  new_test_db()

  run <- launch({
    stow(data.frame(x = 1:3), "cc")
  })

  got <- launch_code(run$run_id)
  expect_type(got, "character")
  expect_length(got, 1L)
  expect_match(got, "stow\\(data.frame\\(x = 1:3\\), \"cc\"\\)")
})

test_that("launch_code() returns the script contents for file-based launches", {
  new_test_db()

  s   <- write_script('stow(data.frame(a = 1), "scripted")')
  run <- launch(s)

  got <- launch_code(run$run_id)
  expect_match(got, "stow\\(data.frame\\(a = 1\\), \"scripted\"\\)")
})

test_that("launch_code() errors on an unknown run_id", {
  new_test_db()
  expect_error(launch_code("run_never_existed"), "no run with run_id")
})

test_that("launch_code() errors when the script is gone from disk", {
  new_test_db()

  s   <- write_script('stow(data.frame(a = 1), "gone")')
  run <- launch(s)
  file.remove(s)

  expect_error(launch_code(run$run_id), "no longer on disk")
})

test_that("launch_code() errors when an interactive write row has no body", {
  new_test_db()

  stow(data.frame(a = 1), "interactively_written")
  # Find the synthetic interactive run row.
  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con,
    "SELECT run_id FROM _mr_runs WHERE status = 'interactive' ORDER BY started_at DESC LIMIT 1"
  )
  expect_error(launch_code(rows$run_id[1]), "no stored code")
})
