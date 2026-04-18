## Helper: write a data frame to a CSV in a test-local tempdir.
write_test_csv <- function(df, envir = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = envir)
  path <- file.path(dir, "data.csv")
  write.csv(df, path, row.names = FALSE)
  path
}

test_that("ingest() loads a CSV, versions metadata carries source_uri and source_hash", {
  new_test_db()
  csv <- write_test_csv(data.frame(x = 1:3, y = letters[1:3]))

  ingest("d", csv)

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT * FROM _mr_versions WHERE logical_name = 'd'")
  expect_equal(nrow(row), 1L)
  expect_equal(normalizePath(row$source_uri[1]), normalizePath(csv))
  expect_true(nzchar(row$source_hash[1]))

  # Grabbing the name returns the ingested data.
  got <- grab("d") |> dplyr::collect()
  expect_equal(got$x, 1:3)
  expect_equal(as.character(got$y), letters[1:3])
})

test_that("grab(source = csv) ingests when the name does not exist", {
  new_test_db()
  csv <- write_test_csv(data.frame(n = 1:4))

  got <- grab("d", source = csv) |> dplyr::collect()
  expect_equal(got$n, 1:4)

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT * FROM _mr_versions WHERE logical_name = 'd'")
  expect_equal(nrow(row), 1L)
})

test_that("grab(source = csv) is a no-op when the file hash hasn't changed", {
  new_test_db()
  csv <- write_test_csv(data.frame(n = 1:4))

  grab("d", source = csv)
  grab("d", source = csv)

  expect_equal(nrow(versions("d")), 1L)
})

test_that("grab(source = csv) ingests a new version when the file changes", {
  new_test_db()
  dir <- withr::local_tempdir()
  csv <- file.path(dir, "data.csv")
  write.csv(data.frame(n = 1:4), csv, row.names = FALSE)

  grab("d", source = csv)

  write.csv(data.frame(n = c(9L, 8L, 7L)), csv, row.names = FALSE)
  got <- grab("d", source = csv) |> dplyr::collect()
  expect_equal(got$n, c(9L, 8L, 7L))
  expect_equal(nrow(versions("d")), 2L)
})

test_that("ingest() works for parquet files", {
  skip_if_not_installed("arrow")
  new_test_db()
  dir <- withr::local_tempdir()
  pq <- file.path(dir, "data.parquet")
  arrow::write_parquet(data.frame(x = 1:5), pq)

  ingest("d", pq)
  expect_equal(dplyr::collect(grab("d"))$x, 1:5)
})

test_that("ingest() errors cleanly on missing file and unsupported extension", {
  new_test_db()
  expect_error(ingest("d", "no-such-file.csv"), "not found|does not exist")

  dir <- withr::local_tempdir()
  bogus <- file.path(dir, "data.xyz")
  writeLines("nope", bogus)
  expect_error(ingest("d", bogus), "extension")
})
