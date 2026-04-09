## DuckDB backend primitives.
##
## These are the only places in the package that are allowed to mention
## DuckDB directly. All other files route through the `.mr_*` helpers
## defined here. See `docs/design.md` §"DuckDB-native in v0.1".

.mr_connect <- function(path) {
  # Create the parent directory lazily.
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  drv <- duckdb::duckdb()
  DBI::dbConnect(drv, dbdir = path, read_only = FALSE)
}

.mr_disconnect <- function(con) {
  if (!is.null(con) && DBI::dbIsValid(con)) {
    DBI::dbDisconnect(con, shutdown = TRUE)
  }
  invisible(NULL)
}

.mr_execute <- function(con, sql, params = NULL) {
  if (is.null(params)) {
    DBI::dbExecute(con, sql)
  } else {
    DBI::dbExecute(con, sql, params = params)
  }
}

.mr_table_exists <- function(con, name) {
  DBI::dbExistsTable(con, name)
}

.mr_list_tables <- function(con) {
  DBI::dbListTables(con)
}

.mr_table_write <- function(con, name, value, overwrite = TRUE) {
  DBI::dbWriteTable(con, name, value, overwrite = overwrite)
}

.mr_table_read <- function(con, name) {
  DBI::dbReadTable(con, name)
}
