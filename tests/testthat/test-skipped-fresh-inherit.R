# Direct unit test of `.mr_record_skipped_fresh`'s inheritance query.
# We seed `_mr_runs` with a success row carrying a real code_hash plus
# a later legacy `skipped_fresh` row whose code_hash is NA, then invoke
# the helper. Pre-fix, the helper's `ORDER BY started_at DESC LIMIT 1`
# query returns the legacy row and the new skipped_fresh row inherits
# NA, perpetuating the chain. Post-fix, the query is constrained to
# `status = 'success'` rows, so the helper finds the success row.

test_that(".mr_record_skipped_fresh inherits code_hash from the latest success row, skipping over NA-coded prior skips", {
  withr::with_tempdir({
    new_test_db()
    con <- modelrunnR:::.mr_get_connection()
    step <- "<inline:abcd1234ef56>"
    real_hash <- "deadbeef000000000000000000000000"

    # Seed a real success row.
    DBI::dbExecute(con, sprintf(
      "INSERT INTO _mr_runs (step, run_id, inputs, outputs, started_at,
         duration_ms, status, code_hash, external_inputs, helpers,
         attached_packages)
       VALUES ('%s', 'run_success_seed', '[]', '[]', '2026-01-01 00:00:00',
               42, 'success', '%s', '{}', '[]', '[]')",
      step, real_hash
    ))
    # Seed a later legacy skipped_fresh row with code_hash = NULL.
    DBI::dbExecute(con, sprintf(
      "INSERT INTO _mr_runs (step, run_id, inputs, outputs, started_at,
         duration_ms, status, code_hash, external_inputs, helpers,
         attached_packages)
       VALUES ('%s', 'run_legacy_NA', '[]', '[]', '2099-01-01 00:00:00',
               0, 'skipped_fresh', NULL, '{}', '[]', '[]')",
      step
    ))

    # Invoke the helper directly. With the fix, it should look past the
    # NA-coded skipped_fresh row and pull code_hash from the success row.
    new_id <- "run_under_test"
    modelrunnR:::.mr_record_skipped_fresh(
      step            = step,
      run_id          = new_id,
      started_at      = Sys.time(),
      external_inputs = list(files = list(), env = list()),
      code_body       = NA_character_,
      label           = NA_character_
    )

    row <- DBI::dbGetQuery(
      con, "SELECT code_hash, status FROM _mr_runs WHERE run_id = ?",
      params = list(new_id)
    )
    expect_equal(row$status,    "skipped_fresh")
    expect_equal(row$code_hash, real_hash)
  })
})
