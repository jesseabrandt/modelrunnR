## Helper that creates a fake project tree with a given marker and walks up
## from a nested subdirectory to exercise .mr_project_root().
make_fake_project <- function(marker, envir = parent.frame()) {
  root <- withr::local_tempdir(.local_envir = envir)
  # Deal with `.git/` (which needs to be a directory) vs regular file markers.
  if (identical(marker, ".git/")) {
    dir.create(file.path(root, ".git"))
  } else {
    file.create(file.path(root, marker))
  }
  sub <- file.path(root, "a", "b", "c")
  dir.create(sub, recursive = TRUE)
  list(root = normalizePath(root, mustWork = TRUE),
       sub  = normalizePath(sub,  mustWork = TRUE))
}

test_that(".mr_project_root finds DESCRIPTION", {
  fp <- make_fake_project("DESCRIPTION")
  expect_equal(.mr_project_root(fp$sub), fp$root)
})

test_that(".mr_project_root finds .Rproj", {
  fp <- make_fake_project(".Rproj")
  expect_equal(.mr_project_root(fp$sub), fp$root)
})

test_that(".mr_project_root finds .git/ directory", {
  fp <- make_fake_project(".git/")
  expect_equal(.mr_project_root(fp$sub), fp$root)
})

test_that(".mr_project_root finds renv.lock", {
  fp <- make_fake_project("renv.lock")
  expect_equal(.mr_project_root(fp$sub), fp$root)
})

test_that(".mr_project_root finds .here", {
  fp <- make_fake_project(".here")
  expect_equal(.mr_project_root(fp$sub), fp$root)
})

test_that(".mr_project_root returns NULL when no marker exists", {
  tmp <- withr::local_tempdir()
  sub <- file.path(tmp, "a", "b")
  dir.create(sub, recursive = TRUE)
  # Walk up into a guaranteed-no-marker subtree. Use the tempdir parent
  # because /tmp itself might contain markers.
  expect_null(.mr_project_root(sub, stop_at = tmp))
})

test_that("db_path() uses the project root when cwd is a nested subdirectory", {
  fp <- make_fake_project("DESCRIPTION")
  withr::local_dir(fp$sub)
  withr::local_options(list(modelrunnR.db = NULL))
  expected <- normalizePath(
    file.path(fp$root, "modelrunnR.duckdb"),
    mustWork = FALSE
  )
  expect_equal(
    normalizePath(db_path(), mustWork = FALSE),
    expected
  )
})

test_that("db_path() warns and falls back to cwd when no project marker is found", {
  tmp <- withr::local_tempdir()
  # Nest two levels deep inside tmp so the walker has somewhere to search.
  sub <- file.path(tmp, "a")
  dir.create(sub)
  withr::local_dir(sub)
  withr::local_options(list(
    modelrunnR.db = NULL,
    modelrunnR.project_stop_at = tmp
  ))

  expect_warning(path <- db_path(), regexp = "project marker")
  expect_equal(
    normalizePath(path, mustWork = FALSE),
    normalizePath(file.path(sub, "modelrunnR.duckdb"), mustWork = FALSE)
  )
})
