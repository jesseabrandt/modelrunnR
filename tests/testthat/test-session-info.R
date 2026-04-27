test_that(".mr_capture_session_info() returns the documented shape", {
  si <- modelrunnR:::.mr_capture_session_info()
  expect_named(si, c(
    "hostname", "os", "arch", "r_version", "n_cpu",
    "total_ram_bytes", "free_ram_bytes", "attached_packages",
    "git_sha", "git_branch", "git_dirty"
  ))
  expect_type(si$hostname,  "character")
  expect_type(si$os,        "character")
  expect_type(si$arch,      "character")
  expect_type(si$r_version, "character")
  expect_true(is.numeric(si$n_cpu) || is.na(si$n_cpu))
  expect_true(is.numeric(si$total_ram_bytes) || is.na(si$total_ram_bytes))
  expect_true(is.numeric(si$free_ram_bytes)  || is.na(si$free_ram_bytes))
  # JSON: attached_packages is always a string, even when empty.
  expect_type(si$attached_packages, "character")
  parsed <- jsonlite::fromJSON(si$attached_packages, simplifyVector = FALSE)
  expect_true(is.list(parsed))
})

test_that(".mr_capture_session_info() falls back to NA on probe failure", {
  # Force ps::ps_system_memory to throw; the wrapper should swallow.
  with_mocked_bindings(
    ps_system_memory = function(...) stop("boom"),
    .package = "ps",
    {
      si <- modelrunnR:::.mr_capture_session_info()
      expect_true(is.na(si$total_ram_bytes))
      expect_true(is.na(si$free_ram_bytes))
    }
  )
})

test_that("R-launch records session-context columns", {
  new_test_db()

  run <- launch({ stow(data.frame(x = 1), "out") })

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT hostname, os, arch, r_version, n_cpu,
            total_ram_bytes, free_ram_bytes, attached_packages
       FROM _mr_runs WHERE run_id = ?",
    params = list(run$run_id)
  )
  expect_equal(nrow(row), 1L)
  expect_false(is.na(row$hostname))
  expect_false(is.na(row$r_version))
  # Linux/Darwin/Windows -- nonempty.
  expect_true(nzchar(row$os))
  # JSON parses; entries (if any) have pkg + ver.
  parsed <- jsonlite::fromJSON(row$attached_packages, simplifyVector = FALSE)
  expect_true(is.list(parsed))
  if (length(parsed) > 0L) {
    expect_true(all(vapply(parsed, function(p) {
      all(c("pkg", "ver") %in% names(p))
    }, logical(1))))
  }
})

test_that("SQL-launch records session-context columns", {
  new_test_db()

  # Seed an append-shape source then run a SQL launch reading it.
  launch({ stow(data.frame(x = 1:3), "src") })
  run <- launch(mr_sql("-- @inputs: src\n-- @output: out\nSELECT x FROM src"))

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT hostname, r_version FROM _mr_runs WHERE run_id = ?",
    params = list(run$run_id)
  )
  expect_equal(nrow(row), 1L)
  expect_false(is.na(row$hostname))
  expect_false(is.na(row$r_version))
})

test_that("skipped_fresh row carries session-context columns", {
  new_test_db()

  launch({ stow(data.frame(a = 1), "x") })
  run2 <- launch({ stow(data.frame(a = 1), "x") })

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT status, hostname, r_version FROM _mr_runs WHERE run_id = ?",
    params = list(run2$run_id)
  )
  expect_equal(nrow(row), 1L)
  expect_equal(row$status, "skipped_fresh")
  expect_false(is.na(row$hostname))
  expect_false(is.na(row$r_version))
})

test_that("interactive stow row carries session-context columns", {
  new_test_db()

  # Bare stow() outside a launch records an interactive run row.
  stow(data.frame(x = 1), "ext")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con,
    "SELECT status, hostname, r_version
       FROM _mr_runs WHERE step LIKE '<interactive:%'
       ORDER BY started_at DESC LIMIT 1"
  )
  expect_equal(nrow(row), 1L)
  expect_equal(row$status, "interactive")
  expect_false(is.na(row$hostname))
  expect_false(is.na(row$r_version))
})

test_that("schema migration is idempotent (re-running adds no columns)", {
  new_test_db()
  con <- .mr_get_connection()
  before <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_runs)")
  modelrunnR:::.mr_migrate_runs(con)
  after  <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_runs)")
  expect_equal(sort(before$name), sort(after$name))
})
