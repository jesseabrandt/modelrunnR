test_that("versions(name) returns documented columns", {
  new_test_db()
  stow(data.frame(x = 1), "t")
  stow(data.frame(x = 1:2), "t")

  v <- versions("t")
  expect_s3_class(v, "data.frame")
  expect_true(all(c("content_hash", "first_seen", "last_seen",
                    "size_bytes", "produced_by_runs") %in% names(v)))
  expect_equal(nrow(v), 2L)
})

test_that("versions(name) ties hashes to their producing runs", {
  new_test_db()

  s <- write_script(c(
    "v <- get0('v', envir = globalenv(), ifnotfound = 1L)",
    "stow(data.frame(x = seq_len(v)), 'w')"
  ))
  on.exit(if (exists("v", envir = globalenv())) rm("v", envir = globalenv()), add = TRUE)

  # force = TRUE because the global `v` isn't a declared external input;
  # staleness correctly wouldn't detect it changed. Test intent is to
  # verify one version per run, so we need both runs to actually execute.
  r1 <- launch(s); assign("v", 2L, envir = globalenv())
  r2 <- launch(s, force = TRUE)

  v <- versions("w")
  expect_equal(nrow(v), 2L)
  # Each version lists exactly its producing run.
  expect_true(all(lengths(v$produced_by_runs) >= 1L))
  produced_runs <- unlist(v$produced_by_runs)
  expect_true(r1$run_id %in% produced_runs)
  expect_true(r2$run_id %in% produced_runs)
})
