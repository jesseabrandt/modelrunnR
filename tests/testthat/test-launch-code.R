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

test_that("launch_code() returns the script file's current contents for file launches", {
  new_test_db()

  s   <- write_script('stow(data.frame(a = 1), "scripted")')
  run <- launch(s)

  got <- launch_code(run$run_id)
  expect_match(got, "stow\\(data.frame\\(a = 1\\), \"scripted\"\\)")
})

test_that("launch_code() falls back to the stored snapshot when the script is gone", {
  new_test_db()

  s   <- write_script('stow(data.frame(a = 1), "gone")')
  run <- launch(s)
  file.remove(s)

  expect_message(
    got <- launch_code(run$run_id),
    "no longer on disk"
  )
  expect_match(got, "stow\\(data.frame\\(a = 1\\), \"gone\"\\)")
})

test_that("launch_code(from_db = TRUE) returns the snapshot even when the file still exists", {
  new_test_db()

  s   <- write_script('stow(data.frame(a = 1), "snap")')
  run <- launch(s)
  # Edit the file after the launch.
  writeLines('stow(data.frame(a = 999), "snap")', s)

  got_file <- launch_code(run$run_id)
  got_snap <- launch_code(run$run_id, from_db = TRUE)

  expect_match(got_file, "a = 999")
  expect_match(got_snap, "a = 1\\)")
})

test_that("launch_code() errors on an unknown run_id", {
  new_test_db()
  expect_error(launch_code("run_never_existed"), "no run with run_id")
})

test_that("launch_code() errors when an interactive write row has no body (append-shape)", {
  new_test_db()

  # Artifacts (non-df) still support interactive stow; they write an
  # interactive _mr_runs row with no code body, just like the old df path.
  stow(list(a = 1), "interactively_written")
  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con,
    "SELECT run_id FROM _mr_runs WHERE status = 'interactive' ORDER BY started_at DESC LIMIT 1"
  )
  expect_error(launch_code(rows$run_id[1]), "no stored code")
})
