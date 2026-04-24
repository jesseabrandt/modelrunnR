test_that("launch(rebind = list(name = df)) stows bare values as Shape A and script grabs them", {
  new_test_db()

  # Bare data frame rebind is stowed as a Shape A (versioned) table.
  # The script grabs the rebound value via the normal Shape A path.
  script <- write_script(c(
    'p <- dplyr::collect(grab("params"))',
    'stow(data.frame(echo = p$x), "out")'
  ))

  launch(script, rebind = list(params = data.frame(x = 42L)))

  expect_equal(dplyr::collect(grab("out", run = "all"))$echo, 42L)
})

test_that("launch(rebind) with mr_run resolves via run outputs for Shape B", {
  new_test_db()

  producer <- write_script('stow(data.frame(v = 1:5), "features")')
  run <- launch(producer)

  consumer <- write_script(c(
    'f <- dplyr::collect(grab("features"))',
    'stow(data.frame(n = nrow(f)), "out")'
  ))
  launch(consumer, rebind = list(features = mr_run(run$run_id)))
  expect_equal(dplyr::collect(grab("out", run = "all"))$n, 5L)
})

test_that("launch(rebind) with mr_variant() resolves to labeled run's rows (Shape B)", {
  new_test_db()

  launch(write_script('stow(data.frame(v = 1:4), "features")'), label = "slow")

  consumer <- write_script(c(
    'f <- dplyr::collect(grab("features"))',
    'stow(data.frame(n = nrow(f)), "out")'
  ))
  launch(consumer, rebind = list(features = mr_variant("slow")))
  expect_equal(dplyr::collect(grab("out", run = "all"))$n, 4L)
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

test_that("mr_variant() in rebind errors when no run has produced the name under that label (Shape B)", {
  new_test_db()
  launch({ stow(data.frame(v = 1), "features") })

  script <- write_script('stow(data.frame(a = 1), "out")')
  expect_error(
    launch(script, rebind = list(features = mr_variant("nobody"))),
    regexp = "mr_variant.*nobody",
    fixed = FALSE
  )
})
