test_that("launch() warns when `script_path` is passed by name and still runs", {
  new_test_db()
  s <- write_script('stow(data.frame(a = 1), "x")')

  expect_warning(
    run <- launch(script_path = s),
    "`script_path` is deprecated"
  )
  expect_equal(run$status, "success")
})

test_that("launch() accepts `code = ` as the new argument name", {
  new_test_db()
  s <- write_script('stow(data.frame(a = 1), "x")')

  run <- launch(code = s)
  expect_equal(run$status, "success")
})

test_that("launch() errors if both `code` and `script_path` are passed", {
  new_test_db()
  s <- write_script('stow(data.frame(a = 1), "x")')

  expect_error(
    launch(code = s, script_path = s),
    "pass `code` only"
  )
})

test_that("launch(script_path = { ... }) still dispatches to inline mode (Shape B)", {
  new_test_db()

  # Use an artifact stow (Shape A) so the block evaluates without a launch
  # context (deprecated script_path shim evaluates the block eagerly when
  # building dots; data-frame stow requires an active recording context).
  run <- suppressWarnings(launch(script_path = {
    stow(list(a = 1), "x")
  }))

  expect_equal(run$status, "success")
  expect_true(startsWith(run$step, "<inline:"))
})

test_that("deprecation shim strips `script_path` before the unknown-args check", {
  new_test_db()
  s <- write_script('stow(data.frame(a = 1), "x")')

  expect_error(
    suppressWarnings(launch(script_path = s, bogus = 1)),
    "unknown arguments: bogus"
  )
})

test_that("launch(script_path = { ... }) and launch(code = { ... }) produce the same step hash (Shape B)", {
  new_test_db()
  # Use artifact stow (Shape A) — script_path shim evaluates the block
  # eagerly in dots; data-frame stow requires an active recording context.
  run_old <- suppressWarnings(launch(script_path = {
    stow(list(a = 1), "x")
  }))

  new_test_db()
  run_new <- launch(code = {
    stow(list(a = 1), "x")
  })

  expect_equal(run_old$step, run_new$step)
})
