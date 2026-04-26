test_that(".mr_as_code attaches mr_code class to character input", {
  x <- .mr_as_code(c("x <- 1", "y <- 2"))
  expect_s3_class(x, "mr_code")
  expect_type(unclass(x), "character")
  expect_equal(unclass(x), c("x <- 1", "y <- 2"))
})

test_that(".mr_as_code preserves NA values and length", {
  x <- .mr_as_code(c("x <- 1", NA_character_, "y <- 2"))
  expect_s3_class(x, "mr_code")
  expect_equal(length(x), 3L)
  expect_true(is.na(unclass(x)[2]))
})

test_that(".mr_as_code on zero-length input yields zero-length mr_code", {
  x <- .mr_as_code(character())
  expect_s3_class(x, "mr_code")
  expect_equal(length(x), 0L)
})

test_that("format.mr_code returns <N chr> for non-NA elements", {
  x <- .mr_as_code(c("abcde", "abcdefghij"))
  expect_equal(format(x), c("<5 chr>", "<10 chr>"))
})

test_that("format.mr_code returns NA for NA elements", {
  x <- .mr_as_code(c("abc", NA_character_))
  out <- format(x)
  expect_equal(out[1], "<3 chr>")
  expect_true(is.na(out[2]))
})

test_that("as.character.mr_code strips the class", {
  raw <- c("x <- 1", "y <- 2")
  x <- .mr_as_code(raw)
  out <- as.character(x)
  expect_identical(out, raw)
  expect_false(inherits(out, "mr_code"))
})

test_that("[.mr_code preserves the class on integer index", {
  x <- .mr_as_code(c("a", "b", "c"))
  expect_s3_class(x[1], "mr_code")
  expect_equal(unclass(x[1]), "a")
})

test_that("[.mr_code preserves the class on logical index", {
  x <- .mr_as_code(c("a", "b", "c"))
  out <- x[c(TRUE, FALSE, TRUE)]
  expect_s3_class(out, "mr_code")
  expect_equal(unclass(out), c("a", "c"))
})

test_that("[.mr_code preserves the class with negative index", {
  x <- .mr_as_code(c("a", "b", "c"))
  expect_s3_class(x[-1], "mr_code")
  expect_equal(unclass(x[-1]), c("b", "c"))
})

test_that("paste0 on mr_code coerces via as.character", {
  x <- .mr_as_code(c("foo", "bar"))
  expect_equal(paste0(x, "!"), c("foo!", "bar!"))
})
