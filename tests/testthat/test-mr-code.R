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

test_that("print.mr_code emits the code body for a single element", {
  x <- .mr_as_code("x <- 1\ny <- 2")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  expect_match(joined, "x <- 1", fixed = TRUE)
  expect_match(joined, "y <- 2", fixed = TRUE)
})

test_that("print.mr_code prints '<no code body>' for NA elements", {
  x <- .mr_as_code(NA_character_)
  out <- capture.output(print(x))
  expect_true(any(grepl("<no code body>", out, fixed = TRUE)))
})

test_that("print.mr_code prints '<no code body>' for empty-string elements", {
  x <- .mr_as_code("")
  out <- capture.output(print(x))
  expect_true(any(grepl("<no code body>", out, fixed = TRUE)))
})

test_that("print.mr_code separates multiple elements with exactly one blank line", {
  x <- .mr_as_code(c("a <- 1", "b <- 2"))
  out <- capture.output(print(x))
  # Expect: line 1 = first code, line 2 = blank, line 3 = second code; no
  # extra trailing or duplicate blanks.
  expect_equal(length(out), 3L)
  expect_equal(sum(out == ""), 1L)
  expect_match(out[1], "a <- 1", fixed = TRUE)
  expect_equal(out[2], "")
  expect_match(out[3], "b <- 2", fixed = TRUE)
})

test_that("print.mr_code returns input invisibly", {
  x <- .mr_as_code("x <- 1")
  res <- withVisible(print(x))
  expect_false(res$visible)
  expect_identical(res$value, x)
})

test_that("print.mr_code emits ANSI escapes when crayon color is enabled", {
  # cli.num_colors is checked before the sink-detection path in num_ansi_colors(),
  # so it reliably forces color even inside capture.output() (which opens a sink).
  withr::local_options(cli.num_colors = 256)
  x <- .mr_as_code("x <- 1")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  expect_true(grepl("\033\\[", joined))
})

test_that("print.mr_code emits no ANSI escapes when color is disabled", {
  withr::local_options(cli.num_colors = 1)
  x <- .mr_as_code("x <- 1")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  expect_false(grepl("\033\\[", joined))
})

test_that("print.mr_code highlights every line of multi-line code (not just the first)", {
  withr::local_options(cli.num_colors = 256)
  x <- .mr_as_code("x <- 1\ny <- 2")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  n_arrows_with_color <- length(gregexpr("\033\\[\\d+m<-", joined)[[1]])
  expect_gte(n_arrows_with_color, 2L)
})
