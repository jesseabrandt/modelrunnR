test_that("downstream inherits a single agreeing upstream label", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  prod <- write_script('stow(data.frame(coef = 0.1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'm <- dplyr::collect(grab("model"))',
    'stow(data.frame(p = m$coef), "preds")'
  ))
  launch(cons)  # no explicit label

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step = ? ORDER BY started_at",
    params = list(normalizePath(cons, mustWork = FALSE))
  )
  expect_equal(rows$variant_label, "eta_0.01")
})

test_that("downstream stays plain when upstreams disagree and warns", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  prod_m <- write_script('stow(data.frame(a = 1),    "model")')
  prod_f <- write_script('stow(data.frame(v = 1), "features")')
  launch(prod_m, label = "eta_0.01")
  launch(prod_f, label = "fast_features")

  cons <- write_script(c(
    'grab("model"); grab("features")',
    'stow(data.frame(a = 1), "out")'
  ))
  expect_warning(launch(cons), regexp = "ambiguous upstream variants")

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step = ? ORDER BY started_at",
    params = list(normalizePath(cons, mustWork = FALSE))
  )
  expect_true(is.na(rows$variant_label))
})

test_that("explicit label wins over propagation without warning", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'grab("model")',
    'stow(data.frame(a = 1), "out")'
  ))
  # launch() emits normal timing/staleness messages; expect_no_warning
  # confirms no propagation-related warning is raised when label= is
  # explicit.
  expect_no_warning({
    launch(cons, label = "explicit_override")
  })

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step = ? ORDER BY started_at",
    params = list(normalizePath(cons, mustWork = FALSE))
  )
  expect_equal(rows$variant_label, "explicit_override")
})

test_that("no labeled upstreams -> plain run, no warning", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod)  # plain

  cons <- write_script(c(
    'grab("model")',
    'stow(data.frame(a = 1), "out")'
  ))
  # launch() emits normal timing/staleness messages; expect_no_warning
  # confirms no propagation-related warning is raised for plain upstreams.
  expect_no_warning(launch(cons))

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step = ? ORDER BY started_at",
    params = list(normalizePath(cons, mustWork = FALSE))
  )
  expect_true(is.na(rows$variant_label))
})
