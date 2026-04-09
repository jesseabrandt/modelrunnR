test_that("launch(label = 'x') writes variant_label on the run row", {
  new_test_db()

  script <- write_script('stow("out", data.frame(a = 1))')
  launch(script, label = "eta_0.01")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_equal(row$variant_label, "eta_0.01")
})

test_that("launch(label = '') and whitespace-only labels error", {
  expect_error(launch("x.R", label = ""),    regexp = "label.*empty",   fixed = FALSE)
  expect_error(launch("x.R", label = "   "), regexp = "label.*empty",   fixed = FALSE)
  expect_error(launch("x.R", label = 42),    regexp = "label.*string",  fixed = FALSE)
})

test_that("launch(label = ' trimmed ') strips whitespace", {
  new_test_db()

  script <- write_script('stow("out", data.frame(a = 1))')
  launch(script, label = "  eta_0.01  ")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_equal(row$variant_label, "eta_0.01")
})

test_that("grab(name, variant = 'x') resolves to latest hash produced under that label", {
  new_test_db()

  fit <- write_script('stow("features", data.frame(v = 1:3))')
  launch(fit, label = "slow")

  fit2 <- write_script('stow("features", data.frame(v = 1:9))')
  launch(fit2, label = "fast")

  expect_equal(nrow(grab("features", variant = "slow")), 3L)
  expect_equal(nrow(grab("features", variant = "fast")), 9L)
})

test_that("grab(variant = 'nonexistent') errors cleanly", {
  new_test_db()

  stow("features", data.frame(v = 1))
  expect_error(
    grab("features", variant = "nothing"),
    regexp = "no variant.*nothing",
    fixed = FALSE
  )
})

test_that("grab() errors on multiple selectors including variant", {
  new_test_db()

  stow("features", data.frame(v = 1))
  expect_error(
    grab("features", variant = "x", version = "abc"),
    regexp = "more than one selector",
    fixed = FALSE
  )
})

test_that("rebind = list(x = mr_variant('slow')) resolves to the labeled variant", {
  new_test_db()

  producer <- write_script('stow("features", data.frame(v = 1:4))')
  launch(producer, label = "slow")

  consumer <- write_script(c(
    'f <- grab("features")',
    'stow("n",  data.frame(n = nrow(f)))'
  ))
  launch(consumer, rebind = list(features = mr_variant("slow")))
  expect_equal(grab("n")$n, 4L)
})
