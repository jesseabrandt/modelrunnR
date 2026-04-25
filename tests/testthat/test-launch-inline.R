test_that("launch({...}) records a run row and tracks stows", {
  new_test_db()

  run <- launch({
    stow(data.frame(x = 1:3), "inline_out")
  })

  expect_equal(run$status, "success")
  expect_true(startsWith(run$step, "<inline:"))

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(con, "SELECT step, outputs FROM _mr_runs WHERE run_id = ?",
                         params = list(run$run_id))
  expect_equal(nrow(rows), 1L)
  expect_match(rows$outputs[1], "inline_out")
})

test_that("launch({...}) sees grab()s recorded as inputs (append-shape)", {
  new_test_db()

  # Write src inside a launch so it's a valid append-shape table.
  launch({ stow(data.frame(a = 1:2), "src") })

  run <- launch({
    df <- grab("src", run = "all") |> dplyr::collect()
    stow(df, "dst")
  })

  expect_match(run$inputs, "src")
  expect_match(run$outputs, "dst")
})

test_that("launch({...}) accepts rebind and label arguments (append-shape)", {
  new_test_db()

  # Bare scalar rebind: stored as versioned-shape literal. grab("base") inside
  # the launch sees the versioned-shape rebound value (a 1-row df).
  run <- launch(
    {
      df <- dplyr::collect(grab("base"))
      stow(data.frame(v = df$v), "tagged")
    },
    rebind = list(base = data.frame(v = 99)),
    label  = "alt"
  )

  expect_equal(run$variant_label, "alt")
  # "tagged" is append-shape; the full-table grab returns run_id + variant_label.
  got <- dplyr::collect(grab("tagged", run = "all"))
  expect_equal(got$v, 99)
})

test_that("launch({...}) re-running the same block is fresh", {
  new_test_db()

  launch({ stow(data.frame(a = 1), "x") })
  msgs <- capture.output(
    launch({ stow(data.frame(a = 1), "x") }),
    type = "message"
  )
  expect_true(any(grepl("is fresh", msgs)))
})

test_that("launch() still accepts a script path", {
  new_test_db()
  s <- write_script('stow(data.frame(a = 1), "keep")')
  run <- launch(s)
  expect_equal(run$status, "success")
  expect_false(startsWith(run$step, "<inline:"))
})

test_that("launch({...}) nested inside another launch errors", {
  new_test_db()

  expect_error(
    launch({
      launch({ stow(data.frame(a = 1), "inner") })
    }),
    "nested launches are not supported"
  )
})
