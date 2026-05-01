# `.mr_is_stale()` keys a step's freshness on (code, inputs, external)
# but not on the resolved rebind map. Per the rebind-aware-staleness
# fix, two launches under the same step + label that differ only in
# their resolved rebind values should be treated as different
# identities — the second launch is NOT fresh against the first.
# A repeated launch with the SAME rebind values stays fresh.

test_that("launches under the same label with different rebind values are not skipped_fresh", {
  withr::with_tempdir({
    new_test_db()
    r1 <- launch(
      { y <- grab("alpha"); stow(data.frame(value = y), "out") },
      rebind = list(alpha = 0.1), label = "sweep"
    )
    expect_equal(r1$status, "success")

    # Same step (identical inline body -> same <inline:hash>), same
    # label, different rebind value -> must run, not skip.
    r2 <- launch(
      { y <- grab("alpha"); stow(data.frame(value = y), "out") },
      rebind = list(alpha = 0.5), label = "sweep"
    )
    expect_equal(r2$status, "success")
    expect_false(r2$run_id == r1$run_id)
  })
})

test_that("launches under the same label with the same rebind value ARE skipped_fresh", {
  withr::with_tempdir({
    new_test_db()
    r1 <- launch(
      { y <- grab("alpha"); stow(data.frame(value = y), "out") },
      rebind = list(alpha = 0.1), label = "sweep"
    )
    expect_equal(r1$status, "success")

    # Same step, same label, identical rebind value -> skip.
    r2 <- launch(
      { y <- grab("alpha"); stow(data.frame(value = y), "out") },
      rebind = list(alpha = 0.1), label = "sweep"
    )
    expect_equal(r2$status, "skipped_fresh")
  })
})

test_that("mr_binds() sweep under one label runs every envelope, not just the first", {
  withr::with_tempdir({
    new_test_db()
    rs <- launch(
      { y <- grab("alpha"); stow(data.frame(value = y), "out") },
      rebind = mr_binds(alpha = c(0.1, 0.5, 1.0)),
      label  = "alpha_sweep"
    )
    expect_equal(nrow(rs), 3L)
    expect_setequal(rs$status, "success")
    expect_equal(length(unique(rs$run_id)), 3L)
  })
})
