test_that(".mr_capture_git_info() returns the documented shape", {
  gi <- modelrunnR:::.mr_capture_git_info()
  expect_named(gi, c("git_sha", "git_branch", "git_dirty"))
  expect_true(is.character(gi$git_sha))
  expect_true(is.character(gi$git_branch))
  expect_true(is.character(gi$git_dirty))
})

test_that(".mr_capture_git_info() is NA across the board outside a repo", {
  tmp <- withr::local_tempdir()
  withr::with_dir(tmp, {
    gi <- modelrunnR:::.mr_capture_git_info()
    expect_true(is.na(gi$git_sha))
    expect_true(is.na(gi$git_branch))
    expect_true(is.na(gi$git_dirty))
  })
})

test_that(".mr_capture_git_info() populates sha + branch in a clean repo", {
  skip_on_cran()
  if (Sys.which("git") == "") skip("git not on PATH")

  tmp <- withr::local_tempdir()
  withr::with_dir(tmp, {
    system2("git", c("init", "-q", "-b", "main"))
    system2("git", c("config", "user.email", "test@example.com"))
    system2("git", c("config", "user.name",  "Test"))
    writeLines("hello", "f.txt")
    system2("git", c("add", "f.txt"))
    system2("git", c("commit", "-q", "-m", "init"))

    gi <- modelrunnR:::.mr_capture_git_info()
    expect_match(gi$git_sha, "^[0-9a-f]{40}$")
    expect_equal(gi$git_branch, "main")
    expect_true(is.na(gi$git_dirty))
  })
})

test_that(".mr_capture_git_info() summarizes uncommitted edits", {
  skip_on_cran()
  if (Sys.which("git") == "") skip("git not on PATH")

  tmp <- withr::local_tempdir()
  withr::with_dir(tmp, {
    system2("git", c("init", "-q", "-b", "main"))
    system2("git", c("config", "user.email", "test@example.com"))
    system2("git", c("config", "user.name",  "Test"))
    writeLines("hello", "f.txt")
    system2("git", c("add", "f.txt"))
    system2("git", c("commit", "-q", "-m", "init"))

    # Modify tracked file + add an untracked one.
    writeLines(c("hello", "world"), "f.txt")
    writeLines("new", "g.txt")

    gi <- modelrunnR:::.mr_capture_git_info()
    expect_false(is.na(gi$git_dirty))
    expect_match(gi$git_dirty, "insertion|untracked")
  })
})

test_that("R-launch records git context columns", {
  new_test_db()

  run <- launch({ stow(data.frame(x = 1), "out") })

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT git_sha, git_branch, git_dirty FROM _mr_runs WHERE run_id = ?",
    params = list(run$run_id)
  )
  expect_equal(nrow(row), 1L)
  # The package source itself lives in a git repo, so capture should
  # have populated something. The exact value is environment-specific;
  # what matters is that the column is present and at least one of the
  # fields came back non-NA when run from inside the working tree.
  expect_true(
    !is.na(row$git_sha) || !is.na(row$git_branch),
    info = "expected git context to populate when tests run inside a repo"
  )
})
