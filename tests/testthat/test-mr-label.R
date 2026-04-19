test_that("launch(mr_label(...)) re-executes an inline labeled pipeline", {
  new_test_db()

  stow(data.frame(x = 1:3), "src")

  launch(
    { stow(grab("src"), "out") },
    label = "baseline"
  )

  # Edit nothing; just relaunch by label. force = TRUE because the
  # default skip-on-fresh would no-op this relaunch (nothing changed).
  # The test's intent is to verify re-execution semantics.
  run <- launch(mr_label("baseline"), force = TRUE)

  expect_equal(run$status, "success")
  expect_match(run$outputs, "out")
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

test_that("launch(mr_label(...)) picks up the most recent iteration", {
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

  launch(mr_label("baseline"))
  # Whatever iteration we ran, the latest "obj" must match the most
  # recent pipeline (a = 99).
  expect_equal(grab("obj")$a, 99L)
})

test_that("launch(mr_label(...)) re-sources a file pipeline when the file still exists", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "filepipe")')
  launch(s, label = "file_pipe")

  run <- launch(mr_label("file_pipe"), force = TRUE)
  expect_equal(run$status, "success")
  expect_equal(run$variant_label, "file_pipe")
})

test_that("launch(mr_label(...)) falls back to the snapshot when the file is gone", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "gone_pipe")')
  launch(s, label = "gone")
  file.remove(s)

  expect_message(
    run <- launch(mr_label("gone")),
    "gone from disk"
  )
  expect_equal(run$status, "success")
  expect_equal(grab("gone_pipe")$a, 1)
})

test_that("launch(mr_label(...)) errors when the label has no runs", {
  new_test_db()
  expect_error(launch(mr_label("nonexistent")), "no run with label")
})

test_that("launch() rejects non-label mr_refs in first position", {
  new_test_db()
  stow(data.frame(v = 1), "x")
  hashes <- versions("x")$content_hash
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
