test_that("mr_file() returns a tagged character of class c('mr_file', 'character')", {
  x <- mr_file("data/training.parquet")
  expect_s3_class(x, "mr_file")
  expect_s3_class(x, "character")
  expect_identical(unclass(x), "data/training.parquet")
})

test_that("mr_file() rejects non-character, length != 1, or empty input", {
  expect_error(mr_file(123), "length-1 non-empty character")
  expect_error(mr_file(c("a", "b")), "length-1 non-empty character")
  expect_error(mr_file(""), "length-1 non-empty character")
  expect_error(mr_file(NA_character_), "length-1 non-empty character")
})

test_that("mr_file() does not require the file to exist", {
  # Lazy validation: existence is checked at the stow site, not at
  # construction. This lets mr_file() values be carried in lists.
  expect_silent(mr_file("/path/that/does/not/exist.csv"))
})

test_that("print.mr_file() renders <mr_file: path>", {
  x <- mr_file("data/training.parquet")
  expect_output(print(x), "<mr_file: data/training.parquet>", fixed = TRUE)
})

test_that("mr_file() is still a character at the bytes level", {
  # Inheriting from "character" means `as.character()` and
  # format-context fallbacks Just Work.
  x <- mr_file("data/training.parquet")
  expect_identical(as.character(x), "data/training.parquet")
})
