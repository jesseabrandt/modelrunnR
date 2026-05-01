test_that("prune(by = 'run') cascades to _mr_append_chunks", {
  withr::with_tempdir({
    new_test_db()
    r1 <- launch({ stow(data.frame(x = 1L), "m") })
    r2 <- launch({ stow(data.frame(x = 2L), "m") }, force = TRUE)

    # Both chunks present pre-prune.
    con <- modelrunnR:::.mr_get_connection()
    pre <- DBI::dbGetQuery(con,
      "SELECT run_id FROM _mr_append_chunks WHERE logical_name = 'm'")
    expect_setequal(pre$run_id, c(r1$run_id, r2$run_id))

    # Prune r1's chunk by run id.
    prune("m", by = "run", run_id = r1$run_id)

    # r1's chunk is gone from the lookup; r2's remains.
    post <- DBI::dbGetQuery(con,
      "SELECT run_id FROM _mr_append_chunks WHERE logical_name = 'm'")
    expect_equal(post$run_id, r2$run_id)

    # versions("m") matches: only r2 surfaces.
    v <- versions("m")
    expect_equal(nrow(v), 1L)
    expect_equal(v$produced_by_runs[[1]], r2$run_id)
  })
})
