## Unit tests for mr_binds() / mr_variants() / mr_envelopes()

test_that("mr_binds(zip) pairs values element-wise", {
  b <- mr_binds(features = mr_variants("a", "b", "c"),
                alpha    = c(0.1, 0.5, 1.0))
  expect_s3_class(b, "mr_binds")
  expect_equal(length(b), 3L)
  expect_equal(b[[1]]$alpha, 0.1)
  expect_equal(b[[2]]$alpha, 0.5)
  expect_equal(b[[1]]$features$value, "a")
  expect_equal(b[[3]]$features$value, "c")
})

test_that("mr_binds(zip) recycles length-1 slots", {
  b <- mr_binds(alpha = c(0.1, 0.5, 1.0), shared = "X")
  expect_equal(length(b), 3L)
  for (env in b) expect_equal(env$shared, "X")
})

test_that("mr_binds(zip) errors on length mismatch and names the odd slot", {
  expect_error(
    mr_binds(a = c(1, 2, 3), b = c(10, 20)),
    "must share length 3.*b=2"
  )
})

test_that("mr_binds(cross) takes the Cartesian product", {
  b <- mr_binds(features = mr_variants("a", "b"),
                alpha    = c(0.1, 0.5, 1.0),
                mode     = "cross")
  expect_equal(length(b), 6L)
  # Every (feature, alpha) pair appears exactly once.
  pairs <- vapply(b, function(env) {
    paste(env$features$value, env$alpha, sep = "/")
  }, character(1))
  expect_equal(length(unique(pairs)), 6L)
})

test_that("mr_binds(cross) iteration order: first slot varies fastest", {
  # Locks the documented behavior so the comment in mr_binds.R stays
  # honest; matches expand.grid()'s convention.
  b <- mr_binds(a = c(1, 2), b = c(10, 20, 30), mode = "cross")
  expect_equal(b[[1]]$a, 1); expect_equal(b[[1]]$b, 10)
  expect_equal(b[[2]]$a, 2); expect_equal(b[[2]]$b, 10)
  expect_equal(b[[3]]$a, 1); expect_equal(b[[3]]$b, 20)
})

test_that("mr_binds() requires at least one named arg", {
  expect_error(mr_binds(), "at least one")
  expect_error(mr_binds(c(1, 2)), "must be named")
})

test_that("mr_binds(.labels) attaches per-envelope labels", {
  b <- mr_binds(alpha = c(0.1, 0.5, 1.0),
                .labels = c("low", "mid", "high"))
  expect_equal(b[[1]]$.label, "low")
  expect_equal(b[[3]]$.label, "high")
})

test_that("mr_binds(.labels) errors on length mismatch", {
  expect_error(
    mr_binds(alpha = c(0.1, 0.5), .labels = c("a", "b", "c")),
    "must equal envelope count"
  )
})

test_that("mr_variants() builds a list of mr_variant refs", {
  v <- mr_variants("clean", "sampled", "raw")
  expect_length(v, 3L)
  expect_true(all(vapply(v, .mr_is_ref, logical(1))))
  expect_equal(v[[1]]$kind, "variant")
  expect_equal(v[[2]]$value, "sampled")
})

test_that("mr_variants() rejects non-strings", {
  expect_error(mr_variants(1, 2), "character")
  expect_error(mr_variants(""), "non-empty")
})

test_that("mr_envelopes() constructs hand-built batches", {
  e <- mr_envelopes(
    list(.label = "baseline",   features = mr_variant("clean"), alpha = 0.1),
    list(features = mr_variant("raw"), alpha = 1.0)
  )
  expect_s3_class(e, "mr_binds")
  expect_equal(length(e), 2L)
  expect_equal(e[[1]]$.label, "baseline")
  expect_null(e[[2]]$.label)
})

test_that("mr_envelopes() rejects empty / unnamed envelopes", {
  expect_error(mr_envelopes(), "at least one")
  expect_error(mr_envelopes(list(1, 2)), "fully-named")
  expect_error(
    mr_envelopes(list(.label = "", x = 1)),
    "non-empty string"
  )
})
