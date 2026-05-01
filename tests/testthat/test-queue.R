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

test_that("queue('script.R') captures file bytes into code_body and computes code_hash", {
  withr::with_tempdir({
    new_test_db()
    writeLines(c("x <- 'hello'", "stow(x, 'greeting')"), "fit.R")
    r <- queue("fit.R")
    expect_equal(r$status, "queued")
    expect_equal(normalizePath(r$step), normalizePath("fit.R"))
    con <- modelrunnR:::.mr_get_connection()
    stored <- DBI::dbGetQuery(con,
      "SELECT code_body, code_hash FROM _mr_runs WHERE run_id = ?",
      params = list(r$run_id))
    expect_match(stored$code_body[1], "hello", fixed = TRUE)
    expect_true(nzchar(stored$code_hash[1]))
  })
})

test_that("queue('missing.R') errors clearly", {
  withr::with_tempdir({
    new_test_db()
    expect_error(queue("does_not_exist.R"), "file not found")
  })
})

test_that("queue('foo.sql') is rejected (out of scope v1)", {
  withr::with_tempdir({
    new_test_db()
    writeLines("SELECT 1", "f.sql")
    expect_error(queue("f.sql"), "out of scope")
  })
})

test_that("queue() with rebind = mr_binds() writes N queued rows under one batch_id", {
  withr::with_tempdir({
    new_test_db()
    r <- queue(
      { x <- grab("alpha") },
      rebind = mr_binds(alpha = c(0.1, 0.5, 1.0))
    )
    expect_equal(nrow(r), 3L)
    expect_true(all(r$status == "queued"))
    expect_equal(length(unique(r$batch_id)), 1L)
    expect_false(is.na(r$batch_id[1]))
    expect_equal(length(unique(r$run_id)), 3L)
  })
})

test_that("each queued batch row's `rebinds` reflects its envelope's resolved rebinds", {
  withr::with_tempdir({
    new_test_db()
    r <- queue(
      { x <- grab("alpha") },
      rebind = mr_binds(alpha = c(0.1, 0.5))
    )
    con <- modelrunnR:::.mr_get_connection()
    rows <- DBI::dbGetQuery(con,
      "SELECT run_id, rebinds FROM _mr_runs WHERE batch_id = ? ORDER BY run_id",
      params = list(r$batch_id[1]))
    expect_match(rows$rebinds[1], "0.1", fixed = TRUE)
    expect_match(rows$rebinds[2], "0.5", fixed = TRUE)
  })
})

test_that("queue(mr_hash('abc')) errors", {
  withr::with_tempdir({
    new_test_db()
    expect_error(queue(mr_hash("abc")), "not accepted as a first-argument reference")
  })
})

test_that("queue(mr_sql('SELECT 1')) errors with out-of-scope message", {
  withr::with_tempdir({
    new_test_db()
    expect_error(queue(mr_sql("SELECT 1")), "out of scope")
  })
})

test_that("batch queue is atomic: a mid-batch error rolls back prior rows", {
  withr::with_tempdir({
    new_test_db()
    con <- modelrunnR:::.mr_get_connection()
    n_before <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n

    # Envelope 2 has an invalid `.label` (whitespace-only). Validation
    # fires inside .mr_queue_batch, after envelope 1's row was written.
    # With transactional rollback, both rows must be absent after error.
    expect_error(
      queue(
        { x <- grab("alpha") },
        rebind = mr_binds(alpha = c(1, 2, 3),
                          .label = c("ok", "  ", "ok2"))
      ),
      regexp = "label"
    )

    n_after <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n
    expect_equal(n_after, n_before)
  })
})

test_that("queue(external_inputs=) hashes the file at queue time and stores on the row", {
  withr::with_tempdir({
    new_test_db()
    writeLines("hello world", "ext.txt")
    q <- queue(
      { x <- 1 },
      external_inputs = list(files = "ext.txt")
    )
    con <- modelrunnR:::.mr_get_connection()
    row <- DBI::dbGetQuery(
      con, "SELECT external_inputs FROM _mr_runs WHERE run_id = ?",
      params = list(q$run_id)
    )
    parsed <- jsonlite::fromJSON(row$external_inputs[1], simplifyVector = FALSE)
    expect_length(parsed$files, 1L)
    expect_match(parsed$files[[1]]$path, "ext\\.txt$")
    expect_match(parsed$files[[1]]$hash, "^[0-9a-f]+$")
  })
})

test_that("queue(external_inputs=) errors at queue time when a declared file is missing", {
  withr::with_tempdir({
    new_test_db()
    expect_error(
      queue({ x <- 1 }, external_inputs = list(files = "no_such.txt")),
      "declared external input file not found"
    )
    con <- modelrunnR:::.mr_get_connection()
    n <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs")$n
    expect_equal(n, 0L)
  })
})

test_that("staged external_inputs survive queue -> pickup; deleted file at pickup stamps row 'error'", {
  withr::with_tempdir({
    new_test_db()
    writeLines("v1", "ext.txt")
    q <- queue(
      { x <- 1 },
      external_inputs = list(files = "ext.txt")
    )
    file.remove("ext.txt")
    expect_error(launch(mr_run(q$run_id)),
                 "declared external input file not found")
    con <- modelrunnR:::.mr_get_connection()
    row <- DBI::dbGetQuery(
      con, "SELECT status FROM _mr_runs WHERE run_id = ?",
      params = list(q$run_id)
    )
    expect_equal(row$status, "error")
  })
})

test_that("batch queue(external_inputs=) shares the resolved record across rows", {
  withr::with_tempdir({
    new_test_db()
    writeLines("data", "ext.txt")
    qs <- queue(
      { x <- grab("alpha") },
      rebind = mr_binds(alpha = c(1, 2)),
      external_inputs = list(files = "ext.txt")
    )
    expect_equal(nrow(qs), 2L)
    con <- modelrunnR:::.mr_get_connection()
    rows <- DBI::dbGetQuery(
      con, "SELECT external_inputs FROM _mr_runs WHERE run_id IN (?, ?)",
      params = list(qs$run_id[1], qs$run_id[2])
    )
    parsed1 <- jsonlite::fromJSON(rows$external_inputs[1], simplifyVector = FALSE)
    parsed2 <- jsonlite::fromJSON(rows$external_inputs[2], simplifyVector = FALSE)
    expect_equal(parsed1$files[[1]]$hash, parsed2$files[[1]]$hash)
  })
})

test_that("queue(mr_label('x')) stages a queued row carrying the labeled body", {
  new_test_db()

  # Seed a labeled run so mr_label("seed") resolves to something.
  launch({ stow(1L, "out_a") }, label = "seed")

  q <- queue(mr_label("seed"))
  expect_equal(q$status, "queued")
  expect_match(q$code_body, "stow(1L", fixed = TRUE)
  # Auto-inherits label from the ref unless overridden.
  expect_equal(q$variant_label, "seed")
})

test_that("queue(mr_label(...), label = 'override') uses the caller's label", {
  new_test_db()
  launch({ stow(1L, "out_b") }, label = "seed2")

  q <- queue(mr_label("seed2"), label = "new_thread")
  expect_equal(q$variant_label, "new_thread")
})

test_that("queue(mr_run(id)) against a success row writes a fresh queued row", {
  new_test_db()
  src <- launch({ stow(1L, "out_c") })

  q <- queue(mr_run(src$run_id))
  expect_equal(q$status, "queued")
  expect_false(identical(q$run_id, src$run_id))
  expect_match(q$code_body, "stow(1L", fixed = TRUE)
})

test_that("queue(mr_run(qid)) against a queued source with no rebind errors as circular", {
  new_test_db()
  q1 <- queue({ stow(1L, "out_d") })

  expect_error(
    queue(mr_run(q1$run_id)),
    "circular"
  )
})

test_that("queue(mr_run(qid)) against a queued source WITH rebind succeeds and leaves source queued", {
  new_test_db()
  q1 <- queue({ stow(grab("x"), "out_e") }, rebind = list(x = 1L))

  q2 <- queue(mr_run(q1$run_id), rebind = list(x = 2L))
  expect_equal(q2$status, "queued")
  expect_false(identical(q2$run_id, q1$run_id))

  # Source stays queued.
  con <- modelrunnR:::.mr_get_connection()
  src <- DBI::dbGetQuery(
    con, "SELECT status FROM _mr_runs WHERE run_id = ?",
    params = list(q1$run_id)
  )
  expect_equal(src$status, "queued")
})

test_that("queue(mr_run(failed_id)) warns under default relaunch_nonsuccess policy", {
  new_test_db()
  on.exit(options(modelrunnR.relaunch_nonsuccess = NULL), add = TRUE)

  src <- tryCatch(launch({ stop("boom") }), error = function(e) NULL)
  failed_id <- DBI::dbGetQuery(
    modelrunnR:::.mr_get_connection(),
    "SELECT run_id FROM _mr_runs WHERE status = 'error' ORDER BY started_at DESC LIMIT 1"
  )$run_id[1]

  expect_warning(
    queue(mr_run(failed_id)),
    "status 'error'"
  )
})

test_that("queue(mr_label('x'), rebind = mr_binds(...)) fans out as a queued batch", {
  new_test_db()
  launch({ stow(grab("alpha"), "out_f") },
         rebind = list(alpha = 0.1),
         label  = "seed3")

  qs <- queue(
    mr_label("seed3"),
    rebind = mr_binds(alpha = c(0.1, 0.5, 1.0))
  )
  expect_equal(nrow(qs), 3L)
  expect_true(all(qs$status == "queued"))
  expect_equal(length(unique(qs$batch_id)), 1L)
  expect_true(all(qs$variant_label == "seed3"))
})
