test_that("grab() returns a lazy tbl for a stowed data.frame", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(x = 1:10, y = letters[1:10], stringsAsFactors = FALSE)
  stow(df, "t")

  got <- grab("t")
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 10L)
})

test_that("grab() on a first-time ingest returns a lazy tbl", {
  new_test_db()
  tmp <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(a = 1:20), tmp, row.names = FALSE)

  got <- grab("csv1", source = tmp)
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 20L)
})

test_that("grab() on an already-ingested table returns a lazy tbl", {
  new_test_db()
  tmp <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(a = 1:20), tmp, row.names = FALSE)
  ingest("csv2", tmp)

  got <- grab("csv2")
  expect_true(inherits(got, "tbl_lazy"))
})

test_that("grab() re-ingests when the source CSV hash changes", {
  new_test_db()
  tmp <- withr::local_tempfile(fileext = ".csv")
  write.csv(data.frame(a = 1:5), tmp, row.names = FALSE)
  grab("csv3", source = tmp)

  write.csv(data.frame(a = 1:10), tmp, row.names = FALSE)
  got <- grab("csv3", source = tmp)
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 10L)
  expect_equal(nrow(mr_versions_rows("csv3")), 2L)
})

test_that("grab() on a stowed non-tabular artifact returns the R object", {
  new_test_db()
  model <- list(coef = c(1, 2, 3), class = "fake_fit")
  class(model) <- "fake_fit"
  stow(model, "m")

  got <- grab("m")
  expect_false(inherits(got, "tbl_lazy"))
  expect_s3_class(got, "fake_fit")
  expect_identical(got$coef, c(1, 2, 3))
})

test_that("grab() lazy tbl composes with dplyr verbs and collects", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(g = rep(letters[1:3], each = 4), v = 1:12)
  stow(df, "t")

  result <- grab("t") |>
    dplyr::group_by(g) |>
    dplyr::summarise(total = sum(v), .groups = "drop") |>
    dplyr::collect()
  expect_equal(nrow(result), 3L)
  expect_setequal(result$g, c("a", "b", "c"))
})

test_that("as.data.frame() on grab() materializes", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(x = 1:5)
  stow(df, "t")

  got <- as.data.frame(grab("t"))
  expect_s3_class(got, "data.frame")
  expect_equal(nrow(got), 5L)
})

test_that("tibble::as_tibble() on grab() materializes", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(x = 1:5)
  stow(df, "t")
  skip_if_not_installed("tibble")

  got <- tibble::as_tibble(grab("t"))
  expect_s3_class(got, "tbl_df")
  expect_equal(nrow(got), 5L)
})

test_that("grab(name, version = hash) on a table returns lazy tbl", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df1 <- data.frame(x = 1:3)
  df2 <- data.frame(x = 1:6)
  stow(df1, "t"); Sys.sleep(0.01)
  stow(df2, "t")

  rows <- mr_versions_rows("t")
  first_hash <- rows$content_hash[1]
  got <- grab("t", version = first_hash)
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 3L)
})

test_that("grab(name, from_run = id) on a table returns lazy tbl", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  df <- data.frame(x = 1:4)
  run <- launch({
    stow(data.frame(x = 1:4), "t")
  }, label = "from_run_test")

  got <- grab("t", from_run = run$run_id)
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 4L)
})

test_that("grab(name, as_of = timestamp) on a table returns lazy tbl", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  stow(data.frame(x = 1:3), "t")
  Sys.sleep(0.05)
  cutoff <- Sys.time()
  Sys.sleep(0.05)
  stow(data.frame(x = 1:7), "t")

  got <- grab("t", as_of = cutoff)
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 3L)
})

test_that("grab(name, variant = label) on a table returns lazy tbl", {
  skip("append-mode stow: expected to rewrite for Shape B in task 16")
  new_test_db()
  launch({ stow(data.frame(x = 1:5), "t") }, label = "variant_a")

  got <- grab("t", variant = "variant_a")
  expect_true(inherits(got, "tbl_lazy"))
  expect_equal(nrow(dplyr::collect(got)), 5L)
})
