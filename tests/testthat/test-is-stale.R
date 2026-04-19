test_that("is_stale(mr_label(...)) returns FALSE after a fresh run", {
  new_test_db()
  launch({ stow(data.frame(a = 1), "out") }, label = "L")

  res <- is_stale(mr_label("L"))
  expect_false(as.logical(res))
  expect_length(attr(res, "reasons"), 0L)
})

test_that("is_stale(mr_label(...)) returns TRUE when an input changes", {
  new_test_db()
  stow(data.frame(x = 1), "training")
  launch({ t <- grab("training"); stow(t, "out") }, label = "L")

  # Restow `training` with different content -- new hash for the input.
  stow(data.frame(x = 2), "training")

  res <- is_stale(mr_label("L"))
  expect_true(as.logical(res))
  expect_true(any(grepl("^input:training$", attr(res, "reasons"))))
})

test_that("is_stale(mr_label(...)) returns TRUE (never_run) for an unused label", {
  new_test_db()
  res <- is_stale(mr_label("nope"))
  expect_true(as.logical(res))
  expect_equal(attr(res, "reasons"), "never_run")
})

test_that("is_stale(mr_variant(...)) is a synonym for mr_label()", {
  new_test_db()
  launch({ stow(data.frame(a = 1), "out") }, label = "L")

  expect_equal(
    as.logical(is_stale(mr_variant("L"))),
    as.logical(is_stale(mr_label("L")))
  )
})

test_that("is_stale() errors clearly on non-label mr_refs", {
  new_test_db()
  expect_error(is_stale(mr_hash("abc")),       "mr_label|mr_variant")
  expect_error(is_stale(mr_run("run_x")),      "mr_label|mr_variant")
  expect_error(
    is_stale(mr_as_of(as.POSIXct("2026-01-01", tz = "UTC"))),
    "mr_label|mr_variant"
  )
})

test_that("is_stale() errors on bare strings, NULL, and non-refs", {
  new_test_db()
  expect_error(is_stale("L"),   "mr_label|mr_variant")
  expect_error(is_stale(NULL),  "mr_label|mr_variant")
  expect_error(is_stale(1L),    "mr_label|mr_variant")
})
