test_that(".mr_validate_name rejects path traversal and separators", {
  expect_error(.mr_validate_name("../etc/passwd"), "path separators")
  expect_error(.mr_validate_name("a/b"), "path separators")
  expect_error(.mr_validate_name("a\\b"), "path separators")
  expect_error(.mr_validate_name(".."), "path separators")
  expect_error(.mr_validate_name("a/../b"), "path separators")
})

test_that(".mr_validate_name rejects control characters", {
  expect_error(.mr_validate_name("a\nb"), "control characters")
  expect_error(.mr_validate_name("a\tb"), "control characters")
  expect_error(.mr_validate_name("a\x01b"), "control characters")
})

test_that(".mr_validate_name rejects non-character, empty, or NA", {
  expect_error(.mr_validate_name(123), "non-empty")
  expect_error(.mr_validate_name(NA_character_), "non-empty")
  expect_error(.mr_validate_name(""), "non-empty")
  expect_error(.mr_validate_name(c("a", "b")), "non-empty")
})

test_that(".mr_validate_name rejects names longer than max_length", {
  long_name <- paste(rep("a", 300), collapse = "")
  expect_error(.mr_validate_name(long_name), "255 characters")
})

test_that(".mr_validate_name accepts normal names", {
  expect_silent(.mr_validate_name("foo"))
  expect_silent(.mr_validate_name("foo_bar"))
  expect_silent(.mr_validate_name("foo.bar"))
  expect_silent(.mr_validate_name("foo-bar"))
  expect_silent(.mr_validate_name("CamelCase"))
})

test_that("stow() rejects names with path traversal", {
  new_test_db()
  expect_error(stow("../evil", data.frame(x = 1)), "path separators")
  expect_error(stow("a/b", data.frame(x = 1)), "path separators")
})

test_that("grab() rejects names with path traversal", {
  new_test_db()
  expect_error(grab("../evil"), "path separators")
})

test_that("ingest() rejects names with path traversal", {
  new_test_db()
  dir <- withr::local_tempdir()
  csv <- file.path(dir, "x.csv")
  writeLines(c("a,b", "1,2"), csv)
  expect_error(ingest("../evil", csv), "path separators")
})
