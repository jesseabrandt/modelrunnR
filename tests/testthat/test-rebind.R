test_that("launch(rebind = list(name = df)) stows bare values", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  script <- write_script(c(
    'p <- dplyr::collect(grab("params"))',
    'stow(data.frame(echo = p$x), "out")'
  ))

  launch(script, rebind = list(params = data.frame(x = 42L)))

  expect_equal(dplyr::collect(grab("out"))$echo, 42L)
})

test_that("launch(rebind) with mr_hash resolves to an existing version", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  stow(data.frame(v = 1:3), "features")
  h <- versions("features")$content_hash[1]

  script <- write_script(c(
    'f <- dplyr::collect(grab("features"))',
    'stow(data.frame(n = nrow(f)), "out")'
  ))
  launch(script, rebind = list(features = mr_hash(h)))
  expect_equal(dplyr::collect(grab("out"))$n, 3L)
})

test_that("launch(rebind) with mr_run resolves via run outputs", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  producer <- write_script('stow(data.frame(v = 1:5), "features")')
  run <- launch(producer)

  consumer <- write_script(c(
    'f <- dplyr::collect(grab("features"))',
    'stow(data.frame(n = nrow(f)), "out")'
  ))
  launch(consumer, rebind = list(features = mr_run(run$run_id)))
  expect_equal(dplyr::collect(grab("out"))$n, 5L)
})

test_that("launch(rebind) with mr_as_of resolves to latest-as-of-time", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  stow(data.frame(v = 1L), "features")
  t0 <- Sys.time()
  Sys.sleep(0.05)
  stow(data.frame(v = 2L), "features")

  script <- write_script(c(
    'f <- dplyr::collect(grab("features"))',
    'stow(data.frame(v = f$v), "out")'
  ))
  launch(script, rebind = list(features = mr_as_of(t0)))
  expect_equal(dplyr::collect(grab("out"))$v, 1L)
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
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(v = 1), "features")

  script <- write_script('stow(data.frame(a = 1), "out")')
  expect_error(
    launch(script, rebind = list(features = mr_variant("nobody"))),
    regexp = "mr_variant.*nobody",
    fixed = FALSE
  )
})
