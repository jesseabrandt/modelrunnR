test_that("launch(data = ...) stows and pins values for the script's grab() calls", {
  new_test_db()

  # A script that reads both 'features' and 'params' and writes a
  # predictions table derived from them.
  s <- write_script(c(
    "features <- grab('features')",
    "params   <- grab('params')",
    "stow('predictions', data.frame(",
    "  pred = features$x * params$mult",
    "))"
  ))

  # Stow 'features' via a tracked writer so grabbing it later doesn't
  # trigger the (correct but noisy) interactive-reproducibility warning.
  writer <- write_script("stow('features', data.frame(x = 1:3))")
  launch(writer)

  run <- launch(s, data = list(params = data.frame(mult = 10)))
  expect_equal(grab("predictions", from_run = run$run_id)$pred, c(10, 20, 30))
})

test_that("parameter sweeps: three launches with different data produce three coexisting versions", {
  new_test_db()

  writer <- write_script("stow('features', data.frame(x = 1:2))")
  launch(writer)

  s <- write_script(c(
    "features <- grab('features')",
    "params   <- grab('params')",
    "stow('predictions', data.frame(pred = features$x + params$bias))"
  ))

  cfgs <- list(
    list(bias = 0),
    list(bias = 10),
    list(bias = 100)
  )
  runs <- lapply(cfgs, function(cfg) {
    launch(s, data = list(params = as.data.frame(cfg)))
  })

  expect_equal(nrow(versions("predictions")), 3L)
  expect_equal(grab("predictions", from_run = runs[[1]]$run_id)$pred, c(1, 2))
  expect_equal(grab("predictions", from_run = runs[[2]]$run_id)$pred, c(11, 12))
  expect_equal(grab("predictions", from_run = runs[[3]]$run_id)$pred, c(101, 102))
})

test_that("pin = list(name = hash) routes grab() to the pinned hash", {
  new_test_db()

  # Write two versions of 'features' via tracked writers.
  w1 <- write_script("stow('features', data.frame(x = 1:2))")
  w2 <- write_script("stow('features', data.frame(x = c(100L, 200L)))")
  launch(w1); launch(w2)

  hashes <- versions("features")$content_hash
  older  <- hashes[1]

  s <- write_script(c(
    "f <- grab('features')",
    "stow('out', f)"
  ))

  run <- launch(s, pin = list(features = older))
  expect_equal(grab("out", from_run = run$run_id)$x, 1:2)
})

test_that("pin accepts a run_id and resolves it to the produced hash", {
  new_test_db()

  # Build a two-run history via tracked writers.
  w_init <- write_script("stow('features', data.frame(x = 1))")
  launch(w_init)
  writer <- write_script("stow('features', data.frame(x = 777))")
  r_old  <- launch(writer)
  w_new  <- write_script("stow('features', data.frame(x = 9999))")
  launch(w_new)

  reader <- write_script("stow('seen', grab('features'))")
  run <- launch(reader, pin = list(features = r_old$run_id))
  expect_equal(grab("seen", from_run = run$run_id)$x, 777)
})

test_that("pin with an unknown hash errors before sourcing the script", {
  new_test_db()
  w <- write_script("stow('features', data.frame(x = 1))")
  launch(w)
  s <- write_script("stow('out', grab('features'))")

  before <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  expect_error(
    launch(s, pin = list(features = "deadbeef")),
    regexp = "resolve|pin"
  )
  after <- DBI::dbGetQuery(.mr_get_connection(), "SELECT COUNT(*) AS c FROM _mr_runs")$c
  expect_equal(after, before)
})

test_that("data and pin together: data stows first; pin wins on name collisions", {
  new_test_db()

  # Two versions of params already exist via tracked writers.
  p1 <- write_script("stow('params', data.frame(k = 1L))")
  p2 <- write_script("stow('params', data.frame(k = 2L))")
  launch(p1); launch(p2)

  hashes <- versions("params")$content_hash
  first_hash <- hashes[1]

  s <- write_script(c(
    "p <- grab('params')",
    "stow('echo', p)"
  ))

  # data passes a fresh params (k = 99), pin overrides to the first version.
  run <- launch(
    s,
    data = list(params = data.frame(k = 99L)),
    pin  = list(params = first_hash)
  )
  expect_equal(grab("echo", from_run = run$run_id)$k, 1L)
})
