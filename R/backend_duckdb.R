## DuckDB backend primitives.
##
## These are the only places in the package that are allowed to mention
## DuckDB directly. All other files route through the `.mr_*` helpers
## defined here. See `docs/design.md` section "DuckDB-native in v0.1".

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

# Check whether `df` has non-default row names. DBI::dbWriteTable
# silently discards row names, so callers should warn the user once
# at the stow() boundary rather than leave the loss unmentioned.
.mr_has_nondefault_rownames <- function(df) {
  if (!is.data.frame(df) || nrow(df) == 0L) return(FALSE)
  rn <- attr(df, "row.names")
  if (is.integer(rn)) return(!identical(rn, seq_len(nrow(df))))
  # Character row names are always non-default.
  TRUE
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

# Read a flat file into a data frame via DuckDB's table functions.
# Dispatches on extension. Slice 4 supports CSV and Parquet; more
# formats land when a real workflow asks for them.
#
# DuckDB's read_csv_auto()/read_parquet() don't accept bound
# parameters in the path slot, so we interpolate after escaping
# single quotes. Paths come from user code, not untrusted input.
.mr_read_file <- function(con, path) {
  if (!file.exists(path)) {
    stop(sprintf("ingest(): file does not exist: %s", path), call. = FALSE)
  }
  ext <- tolower(tools::file_ext(path))
  reader <- switch(
    ext,
    csv     = "read_csv_auto",
    tsv     = "read_csv_auto",
    parquet = "read_parquet",
    pq      = "read_parquet",
    stop(sprintf("ingest(): unsupported file extension '%s'", ext), call. = FALSE)
  )
  escaped <- gsub("'", "''", normalizePath(path, mustWork = TRUE), fixed = TRUE)
  sql <- sprintf("SELECT * FROM %s('%s')", reader, escaped)
  DBI::dbGetQuery(con, sql)
}

# Content-hash a data frame in a row- and column-order-independent way.
#
# Algorithm:
#   1. Write `df` to a transient DuckDB temp table.
#   2. Compute a per-row hash using DuckDB HASH() over columns in sorted
#      column-name order. This makes the hash invariant to column order.
#   3. STRING_AGG the row hashes in sorted row-hash order, separated by
#      '|'. ORDER BY inside STRING_AGG is what makes the aggregate
#      row-order invariant (up to 64-bit HASH collisions; see below)
#      while preserving row multiplicity.
#   4. MD5 the aggregate string. Gives a compact 32-char hex digest that
#      round-trips as VARCHAR.
#
# Caveat: the ORDER BY sort key is a 64-bit UBIGINT, so row pairs that
# hash to the same value break the total-order guarantee. Birthday-bound
# collision probability is ~0.03% at 100M distinct rows, acceptable at
# v0.1 scale; a deterministic tiebreaker is tracked in docs/followups.md.
# Type-sensitive: HASH(INTEGER 1) != HASH(DOUBLE 1.0), so changing a
# column's R storage type produces a new version.
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
