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

.mr_drop_table <- function(con, name) {
  DBI::dbRemoveTable(con, name)
}

.mr_quote_ident <- function(name) {
  sprintf('"%s"', gsub('"', '""', name, fixed = TRUE))
}

# Content-hash a data frame in a row- and column-order-independent way.
#
# Algorithm (Slice 3 commitment; may be revisited):
#   1. Write `df` to a transient DuckDB temp table.
#   2. Compute a per-row hash using DuckDB HASH() over columns in sorted
#      column-name order. This makes the hash invariant to column order.
#   3. STRING_AGG the row hashes in sorted row-hash order, separated by
#      '|'. ORDER BY inside STRING_AGG is what makes the aggregate
#      row-order invariant while preserving row multiplicity.
#   4. MD5 the aggregate string. Gives a compact 32-char hex digest that
#      round-trips as VARCHAR.
#
# An empty frame hashes on its sorted column names alone.
.mr_hash_frame <- function(con, df) {
  cols <- sort(names(df))

  if (nrow(df) == 0L) {
    empty_key <- paste0("empty|", paste(cols, collapse = ","))
    sql <- sprintf("SELECT MD5('%s') AS h", gsub("'", "''", empty_key, fixed = TRUE))
    return(DBI::dbGetQuery(con, sql)$h[[1]])
  }

  tmp <- paste0(
    "_mr_tmp_hash_",
    paste(sample(c(0:9, letters), 10, replace = TRUE), collapse = "")
  )
  .mr_table_write(con, tmp, df, overwrite = TRUE)
  on.exit(try(.mr_drop_table(con, tmp), silent = TRUE), add = TRUE)

  cols_sql <- paste(vapply(cols, .mr_quote_ident, character(1)), collapse = ", ")
  sql <- sprintf(
    "SELECT MD5(STRING_AGG(CAST(HASH(%s) AS VARCHAR), '|' ORDER BY HASH(%s))) AS h FROM %s",
    cols_sql, cols_sql, .mr_quote_ident(tmp)
  )
  DBI::dbGetQuery(con, sql)$h[[1]]
}
