test_that("_mr_append_tables is created on connect with the expected columns", {
  new_test_db()
  con <- .mr_get_connection()
  expect_true(DBI::dbExistsTable(con, "_mr_append_tables"))
  info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_append_tables)")
  expect_setequal(
    info$name,
    c("logical_name", "physical_name", "schema_json",
      "first_seen", "last_seen", "row_count", "size_bytes")
  )
  pk <- info[info$pk == 1L, "name"]
  expect_identical(pk, "logical_name")
})

test_that("migration is idempotent", {
  new_test_db()
  con <- .mr_get_connection()
  # Force-run migrations a second time; must not error.
  expect_silent(.mr_migrate(con))
  expect_silent(.mr_migrate(con))
})

test_that(".mr_lookup_shape returns NULL for unknown name, 'A' for versioned, 'B' for append", {
  new_test_db()
  expect_null(.mr_lookup_shape("nothing_here"))

  con <- .mr_get_connection()
  # Seed versioned-shape directly.
  DBI::dbExecute(con,
    "INSERT INTO _mr_versions (logical_name, content_hash, physical_name, kind,
                               first_seen, last_seen, size_bytes)
     VALUES ('versioned_thing', 'h', 'versioned_thing__h', 'table',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 0)")
  expect_identical(.mr_lookup_shape("versioned_thing"), "A")

  # Seed append-shape directly.
  DBI::dbExecute(con,
    "INSERT INTO _mr_append_tables (logical_name, physical_name, schema_json,
                                     first_seen, last_seen, row_count, size_bytes)
     VALUES ('append_thing', 'append_thing__append', '{}',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 0, 0)")
  expect_identical(.mr_lookup_shape("append_thing"), "B")
})

test_that(".mr_guard_namespace errors on cross-shape name collision", {
  new_test_db()
  con <- .mr_get_connection()
  DBI::dbExecute(con,
    "INSERT INTO _mr_append_tables (logical_name, physical_name, schema_json,
                                     first_seen, last_seen, row_count, size_bytes)
     VALUES ('shared', 'shared__append', '{}',
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 0, 0)")
  # Attempting to register versioned-shape under the same name must error.
  expect_error(
    .mr_guard_namespace("shared", shape = "A", new_kind = "artifact"),
    "already exists as an append"
  )
})
