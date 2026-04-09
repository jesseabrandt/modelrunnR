test_that("launch(rebind = list(name = df)) stows bare values", {
  new_test_db()

  script <- write_script(c(
    'p <- grab("params")',
    'stow("out", data.frame(echo = p$x))'
  ))

  launch(script, rebind = list(params = data.frame(x = 42L)))

  expect_equal(grab("out")$echo, 42L)
})

test_that("launch(rebind) with mr_hash resolves to an existing version", {
  new_test_db()

  stow("features", data.frame(v = 1:3))
  h <- versions("features")$content_hash[1]

  script <- write_script(c(
    'f <- grab("features")',
    'stow("out", data.frame(n = nrow(f)))'
  ))
  launch(script, rebind = list(features = mr_hash(h)))
  expect_equal(grab("out")$n, 3L)
})

test_that("launch(rebind) with mr_run resolves via run outputs", {
  new_test_db()

  producer <- write_script('stow("features", data.frame(v = 1:5))')
  run <- launch(producer)

  consumer <- write_script(c(
    'f <- grab("features")',
    'stow("out", data.frame(n = nrow(f)))'
  ))
  launch(consumer, rebind = list(features = mr_run(run$run_id)))
  expect_equal(grab("out")$n, 5L)
})

test_that("launch(rebind) with mr_as_of resolves to latest-as-of-time", {
  new_test_db()

  stow("features", data.frame(v = 1L))
  t0 <- Sys.time()
  Sys.sleep(0.05)
  stow("features", data.frame(v = 2L))

  script <- write_script(c(
    'f <- grab("features")',
    'stow("out", data.frame(v = f$v))'
  ))
  launch(script, rebind = list(features = mr_as_of(t0)))
  expect_equal(grab("out")$v, 1L)
})

test_that("launch(pin = ...) is a hard error with a migration message", {
  expect_error(
    launch("nonexistent.R", pin = list(p = "abc")),
    regexp = "pin.*removed.*rebind",
    fixed = FALSE
  )
})

test_that("launch(data = ...) is a hard error with a migration message", {
  expect_error(
    launch("nonexistent.R", data = list(p = data.frame(x = 1))),
    regexp = "data.*removed.*rebind",
    fixed = FALSE
  )
})

test_that("mr_variant() in rebind errors when no run has produced the name under that label", {
  new_test_db()
  stow("features", data.frame(v = 1))

  script <- write_script('stow("out", data.frame(a = 1))')
  expect_error(
    launch(script, rebind = list(features = mr_variant("nobody"))),
    regexp = "mr_variant.*nobody",
    fixed = FALSE
  )
})
