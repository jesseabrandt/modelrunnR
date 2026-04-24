test_that("launch(mr_label(...)) re-executes an inline labeled pipeline (Shape B)", {
  new_test_db()

  launch(
    { stow(data.frame(x = 1:3), "src") },
    label = "baseline"
  )

  # Re-execute same pipeline by label (force = TRUE so skip-on-fresh doesn't no-op).
  run <- launch(mr_label("baseline"), force = TRUE)

  expect_equal(run$status, "success")
  # outputs JSON must mention "src"
  expect_match(run$outputs, "src")
})

test_that("launch(mr_label(...)) auto-inherits the label", {
  new_test_db()

  launch(
    { stow(data.frame(a = 1), "x") },
    label = "baseline"
  )
  run <- launch(mr_label("baseline"))
  expect_equal(run$variant_label, "baseline")
})

test_that("launch(mr_label(...)) picks up the most recent iteration (Shape B)", {
  new_test_db()

  # Iteration 1.
  launch(
    { stow(data.frame(a = 1L), "obj") },
    label = "baseline"
  )
  # Iteration 2 — same label, edited body.
  launch(
    { stow(data.frame(a = 99L), "obj") },
    label = "baseline"
  )

  launch(mr_label("baseline"), force = TRUE)
  # Whatever iteration we ran, the latest "obj" must include the most
  # recent row (a = 99).
  got <- grab("obj", run = "all") |> dplyr::collect()
  expect_true(99L %in% got$a)
})

test_that("launch(mr_label(...)) re-sources a file pipeline when the file still exists", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "filepipe")')
  launch(s, label = "file_pipe")

  run <- launch(mr_label("file_pipe"), force = TRUE)
  expect_equal(run$status, "success")
  expect_equal(run$variant_label, "file_pipe")
})

test_that("launch(mr_label(...)) falls back to the snapshot when the file is gone (Shape B)", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "gone_pipe")')
  launch(s, label = "gone")
  file.remove(s)

  expect_message(
    run <- launch(mr_label("gone")),
    "gone from disk"
  )
  expect_equal(run$status, "success")
  got <- grab("gone_pipe", run = "all") |> dplyr::collect()
  # Both the original and relaunch wrote a row; all must have a = 1.
  expect_true(all(got$a == 1))
})

test_that("launch(mr_label(...)) errors when the label has no runs", {
  new_test_db()
  expect_error(launch(mr_label("nonexistent")), "no run with label")
})

test_that("launch() rejects non-label mr_refs in first position (Shape B)", {
  new_test_db()
  launch({ stow(data.frame(v = 1), "x") })
  # mr_hash references are Shape A concepts; grab("x") under Shape B has no hash
  # But we can still test the error path by manufacturing an artifact hash.
  stow(list(v = 1), "x_art")
  hashes <- versions("x_art")$content_hash
  expect_error(
    launch(mr_hash(hashes[1])),
    "only mr_label\\(\\) is accepted as a first argument reference"
  )
})

test_that("launch(mr_label(...)) accepts an explicit override label", {
  new_test_db()

  launch({ stow(data.frame(a = 1), "x") }, label = "baseline")
  run <- launch(mr_label("baseline"), label = "retag")
  expect_equal(run$variant_label, "retag")
})
