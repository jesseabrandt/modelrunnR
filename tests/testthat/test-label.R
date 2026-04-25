test_that("launch(label = 'x') writes variant_label on the run row", {
  new_test_db()

  script <- write_script('stow(data.frame(a = 1), "out")')
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

  script <- write_script('stow(data.frame(a = 1), "out")')
  launch(script, label = "  eta_0.01  ")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_equal(row$variant_label, "eta_0.01")
})

test_that("grab(name, variant = 'x') resolves to rows from the latest run under that label (append-shape)", {
  new_test_db()

  fit <- write_script('stow(data.frame(v = 1:3), "features")')
  launch(fit, label = "slow")

  fit2 <- write_script('stow(data.frame(v = 1:9), "features")')
  launch(fit2, label = "fast")

  expect_equal(nrow(dplyr::collect(grab("features", variant = "slow"))), 3L)
  expect_equal(nrow(dplyr::collect(grab("features", variant = "fast"))), 9L)
})

test_that("grab(variant = 'nonexistent') errors cleanly (append-shape)", {
  new_test_db()

  launch({ stow(data.frame(v = 1), "features") })
  expect_error(
    grab("features", variant = "nothing"),
    regexp = "no.*variant.*nothing|no run with variant",
    fixed = FALSE
  )
})

test_that("grab() errors on multiple selectors including variant (append-shape)", {
  new_test_db()

  launch({ stow(data.frame(v = 1), "features") })
  expect_error(
    grab("features", variant = "x", from_run = "abc"),
    regexp = "more than one selector",
    fixed = FALSE
  )
})

test_that("rebind = list(x = mr_variant('slow')) resolves to the labeled variant (append-shape)", {
  new_test_db()

  producer <- write_script('stow(data.frame(v = 1:4), "features")')
  launch(producer, label = "slow")

  consumer <- write_script(c(
    'f <- dplyr::collect(grab("features"))',
    'stow(data.frame(n = nrow(f)),  "n")'
  ))
  launch(consumer, rebind = list(features = mr_variant("slow")))
  expect_equal(dplyr::collect(grab("n", run = "all"))$n, 4L)
})

test_that("grab(variant = 'x') inside launch() records the read on the run row (append-shape)", {
  new_test_db()

  prod <- write_script('stow(data.frame(v = 1:3), "features")')
  launch(prod, label = "slow")

  cons <- write_script(c(
    'f <- grab("features", variant = "slow")',
    'stow(data.frame(n = nrow(f)), "n")'
  ))
  run <- launch(cons)

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(
    con, "SELECT inputs FROM _mr_runs WHERE run_id = ?",
    params = list(run$run_id)
  )
  pairs <- jsonlite::fromJSON(row$inputs[1], simplifyVector = FALSE)
  input_names <- vapply(pairs, function(p) p$name, character(1))
  expect_true("features" %in% input_names)
})
