# Tests for the is_rebind flag on `_mr_versions`. Bare-value rebinds
# write a row but mark it `is_rebind = TRUE` so naked grab(name) and
# the latest-version view exclude it. This keeps a launch's sample
# rebind from shadowing the real upstream value.

test_that("bare-value rebind writes is_rebind = TRUE row to _mr_versions", {
  new_test_db()
  launch({ x <- grab("alpha") }, rebind = list(alpha = 0.42))
  rows <- mr_versions_rows("alpha")
  expect_equal(nrow(rows), 1L)
  expect_true(isTRUE(as.logical(rows$is_rebind[1])))
})

test_that("naked grab(name) returns the real upstream after a launch with bare rebind", {
  new_test_db()

  # Real upstream stow as Shape A (versioned) so a bare-frame rebind on
  # the same name is a valid shape match.
  launch({ stow(data.frame(v = 99L), "params", shape = "versioned") })

  # Launch with a bare-value rebind that supplies a *different* sample value.
  launch({
    inside <- dplyr::collect(grab("params"))
    stow(data.frame(saw = inside$v), "saw")
  }, rebind = list(params = data.frame(v = -1L)))

  # Inside the launch, the rebind short-circuits and grab() returns the
  # rebound sample (-1).
  saw_inside <- dplyr::collect(grab("saw", run = "all"))
  expect_equal(saw_inside$saw, -1L)

  # But after the launch, naked grab("params") must return the real
  # upstream (99), NOT the rebound sample.
  outside <- dplyr::collect(grab("params"))
  expect_equal(outside$v, 99L)
})

test_that("versions(name) default returns rebind rows alongside real versions", {
  new_test_db()
  launch({ x <- grab("alpha") }, rebind = list(alpha = 0.1))
  launch({ x <- grab("alpha") }, rebind = list(alpha = 0.5))

  v <- versions("alpha")
  expect_equal(nrow(v), 2L)
})

test_that("versions(name, include_rebinds = FALSE) filters rebind rows out", {
  new_test_db()
  launch({ x <- grab("alpha") }, rebind = list(alpha = 0.1))
  launch({ x <- grab("alpha") }, rebind = list(alpha = 0.5))

  v_all <- versions("alpha")
  v_real <- versions("alpha", include_rebinds = FALSE)
  expect_equal(nrow(v_all), 2L)
  expect_equal(nrow(v_real), 0L)
})

test_that("mr_hash(<rebind_hash>) still resolves to the rebound value", {
  new_test_db()
  launch({ x <- grab("alpha") }, rebind = list(alpha = 0.42))
  v <- versions("alpha")
  rebind_hash <- v$content_hash[1]

  # Re-launch with mr_hash() pointing at the rebind row. Should resolve
  # without error and feed the rebound value back into the script.
  launch({
    y <- grab("alpha")
    stow(data.frame(echo = y), "echo")
  }, rebind = list(alpha = mr_hash(rebind_hash)))

  echo <- dplyr::collect(grab("echo", run = "all"))
  expect_equal(echo$echo, 0.42)
})

test_that("re-launch with the same bare value is skipped_fresh", {
  new_test_db()
  r1 <- launch(
    { y <- grab("alpha"); stow(data.frame(value = y), "out") },
    rebind = list(alpha = 0.1)
  )
  expect_equal(r1$status, "success")

  r2 <- launch(
    { y <- grab("alpha"); stow(data.frame(value = y), "out") },
    rebind = list(alpha = 0.1)
  )
  expect_equal(r2$status, "skipped_fresh")
})

test_that("re-launch with a different bare value re-fires (not skipped_fresh)", {
  new_test_db()
  r1 <- launch(
    { y <- grab("alpha"); stow(data.frame(value = y), "out") },
    rebind = list(alpha = 0.1)
  )
  expect_equal(r1$status, "success")

  r2 <- launch(
    { y <- grab("alpha"); stow(data.frame(value = y), "out") },
    rebind = list(alpha = 0.5)
  )
  expect_equal(r2$status, "success")
  expect_false(r2$run_id == r1$run_id)
})

test_that("inside a launch, grab(name) returns the rebind value (state short-circuits)", {
  new_test_db()
  # No upstream stow exists for `alpha`. Inside-launch grab works only
  # because .mr_state$rebinds short-circuits the resolver.
  launch({
    y <- grab("alpha")
    stow(data.frame(value = y), "captured")
  }, rebind = list(alpha = 0.77))

  cap <- dplyr::collect(grab("captured", run = "all"))
  expect_equal(cap$value, 0.77)
})

test_that("bare-rebind-only name errors on naked grab() outside any launch", {
  new_test_db()
  # Only a bare-rebind row exists for `test_year` — no real upstream.
  launch({ x <- grab("test_year") }, rebind = list(test_year = 2010L))

  # Outside any launch, naked grab() should error: there is no real
  # upstream version of `test_year`, only a shadowed rebind row.
  expect_error(grab("test_year"), "no value stowed under 'test_year'")
})

test_that("mr_binds() with bare scalars writes N is_rebind rows; naked grab errors", {
  new_test_db()
  rs <- launch(
    { y <- grab("test_year"); stow(data.frame(value = y), "out") },
    rebind = mr_binds(test_year = c(2010L, 2011L, 2012L)),
    label  = "year_sweep"
  )
  expect_equal(nrow(rs), 3L)

  # Each envelope wrote a distinct rebind row (3 distinct values).
  rows <- mr_versions_rows("test_year")
  expect_equal(nrow(rows), 3L)
  expect_true(all(as.logical(rows$is_rebind)))

  # versions() default surfaces all 3.
  v <- versions("test_year")
  expect_equal(nrow(v), 3L)

  # versions(include_rebinds = FALSE) surfaces none.
  v_real <- versions("test_year", include_rebinds = FALSE)
  expect_equal(nrow(v_real), 0L)

  # Naked grab() outside any launch errors — `test_year` has no real
  # upstream.
  expect_error(grab("test_year"), "no value stowed")
})
