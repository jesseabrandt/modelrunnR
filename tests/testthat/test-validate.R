test_that(".mr_validate_name rejects path traversal and separators", {
  expect_error(.mr_validate_name("../etc/passwd"), "letters, digits, and underscores")
  expect_error(.mr_validate_name("a/b"),           "letters, digits, and underscores")
  expect_error(.mr_validate_name("a\\b"),          "letters, digits, and underscores")
  expect_error(.mr_validate_name(".."),            "letters, digits, and underscores")
  expect_error(.mr_validate_name("a/../b"),        "letters, digits, and underscores")
})

test_that(".mr_validate_name rejects control characters", {
  expect_error(.mr_validate_name("a\nb"), "letters, digits, and underscores")
  expect_error(.mr_validate_name("a\tb"), "letters, digits, and underscores")
  expect_error(.mr_validate_name("a\x01b"), "letters, digits, and underscores")
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

test_that(".mr_validate_name rejects hyphens, dots, spaces, leading digits", {
  # 2026-04-24: allowlist tightened to [A-Za-z_][A-Za-z0-9_]* so the
  # SQL-launch `\b<name>\b` substitution is provably safe against
  # collisions like "features" matching inside "features-v2".
  expect_error(.mr_validate_name("foo.bar"),  "letters, digits, and underscores")
  expect_error(.mr_validate_name("foo-bar"),  "letters, digits, and underscores")
  expect_error(.mr_validate_name("foo bar"),  "letters, digits, and underscores")
  expect_error(.mr_validate_name("1foo"),     "letters, digits, and underscores")
})

test_that(".mr_validate_name accepts normal names", {
  expect_silent(.mr_validate_name("foo"))
  expect_silent(.mr_validate_name("foo_bar"))
  expect_silent(.mr_validate_name("CamelCase"))
  expect_silent(.mr_validate_name("foo_1"))
  expect_silent(.mr_validate_name("_leading_underscore"))
})

test_that(".mr_validate_name rejects the `_mr_` reserved prefix", {
  expect_error(.mr_validate_name("_mr_runs"),         "reserved")
  expect_error(.mr_validate_name("_mr_versions"),     "reserved")
  expect_error(.mr_validate_name("_mr_anything"),     "reserved")
  # Single underscore-leading names that aren't `_mr_*` are still fine:
  expect_silent(.mr_validate_name("_my_thing"))
  expect_silent(.mr_validate_name("_mr"))     # exact `_mr` (no trailing _)
})

test_that("stow() rejects names with path traversal", {
  new_test_db()
  expect_error(stow(data.frame(x = 1), "../evil"), "letters, digits, and underscores")
  expect_error(stow(data.frame(x = 1), "a/b"),     "letters, digits, and underscores")
})

test_that("grab() rejects names with path traversal", {
  new_test_db()
  expect_error(grab("../evil"), "letters, digits, and underscores")
})

test_that("ingest() rejects names with path traversal", {
  new_test_db()
  dir <- withr::local_tempdir()
  csv <- file.path(dir, "x.csv")
  writeLines(c("a,b", "1,2"), csv)
  suppressWarnings(expect_error(ingest("../evil", csv), "letters, digits, and underscores"))
})
