# Test helpers for isolating each test's DuckDB artifact store.

# Create a fresh, isolated DB path inside a test-local temp directory, set it
# as the active modelrunnR DB for the duration of the caller's test
# (withr::defer_parent on cleanup), and make sure any previously-cached
# connection in .mr_state is cleared so the option takes effect.
new_test_db <- function(envir = parent.frame()) {
  tmp <- withr::local_tempdir(.local_envir = envir)
  db  <- file.path(tmp, "test.duckdb")
  withr::local_options(
    list(modelrunnR.db = db),
    .local_envir = envir
  )
  # Close any open cached connection so the new path is picked up.
  .mr_reset_connection()
  withr::defer(.mr_reset_connection(), envir = envir)
  db
}

# Write a script file in a temp directory and return its path.
write_script <- function(code, envir = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = envir)
  path <- file.path(dir, "script.R")
  writeLines(code, path)
  path
}
