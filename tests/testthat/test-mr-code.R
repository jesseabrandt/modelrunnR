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

test_that("[[.mr_code preserves the class on integer index", {
  x <- .mr_as_code(c("a <- 1", "b <- 2", "c <- 3"))
  expect_s3_class(x[[2]], "mr_code")
  expect_equal(unclass(x[[2]]), "b <- 2")
})

test_that(".mr_as_code is idempotent — re-applying does not stack the class", {
  x <- .mr_as_code(c("a", "b"))
  y <- .mr_as_code(x)
  expect_identical(class(y), class(x))
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
  # Pin: no ANSI in output. Otherwise a CI runner with FORCE_COLOR=1 or a
  # globally-set cli.num_colors would slip escape codes into out[1]/out[3]
  # and the substring expect_match calls would fail.
  withr::local_options(cli.num_colors = 1)
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

test_that("knit_print.mr_code returns a knit_asis fenced r block with the code body", {
  skip_if_not_installed("knitr")
  x <- .mr_as_code("x <- 1\ny <- 2")
  out <- knit_print.mr_code(x)
  expect_s3_class(out, "knit_asis")
  s <- as.character(out)
  expect_match(s, "```r", fixed = TRUE)
  expect_match(s, "x <- 1", fixed = TRUE)
  expect_match(s, "y <- 2", fixed = TRUE)
  # No ANSI escapes: highlighting is Pandoc's job, not ours.
  expect_false(grepl("\033\\[", s))
})

test_that("knit_print.mr_code emits one fenced block per element", {
  skip_if_not_installed("knitr")
  x <- .mr_as_code(c("a <- 1", "b <- 2"))
  s <- as.character(knit_print.mr_code(x))
  # Two opening ```r fences for two elements.
  expect_equal(length(gregexpr("```r", s, fixed = TRUE)[[1]]), 2L)
  expect_match(s, "a <- 1", fixed = TRUE)
  expect_match(s, "b <- 2", fixed = TRUE)
})

test_that("knit_print.mr_code renders NA / empty elements as <no code body>", {
  skip_if_not_installed("knitr")
  s <- as.character(knit_print.mr_code(.mr_as_code(NA_character_)))
  expect_match(s, "<no code body>", fixed = TRUE)
  s2 <- as.character(knit_print.mr_code(.mr_as_code("")))
  expect_match(s2, "<no code body>", fixed = TRUE)
})

test_that("knit_print.mr_code swallows knitr's options/inline arguments via ...", {
  skip_if_not_installed("knitr")
  x <- .mr_as_code("x <- 1")
  expect_no_error(capture.output(knit_print.mr_code(x, options = list(echo = TRUE), inline = FALSE)))
})

test_that("print.mr_code highlights every line of multi-line code (not just the first)", {
  withr::local_options(cli.num_colors = 256)
  x <- .mr_as_code("x <- 1\ny <- 2")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  n_arrows_with_color <- length(gregexpr("\033\\[\\d+m<-", joined)[[1]])
  expect_gte(n_arrows_with_color, 2L)
})
