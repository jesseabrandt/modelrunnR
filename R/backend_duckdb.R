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
  # Null-byte guard: most C-level parsers treat nul as string terminator.
  # Check the raw bytes rather than the R string (R strings cannot
  # contain embedded nuls natively, but a file system or external API
  # could still smuggle one in).
  if (any(charToRaw(path) == as.raw(0L))) {
    stop("stow(): path contains a null byte.", call. = FALSE)
  }
  # Normalize first so `file.exists` and the SQL interpolation agree
  # on the canonical path (closes a small TOCTOU gap where a relative
  # path could resolve differently between the two calls).
  normalized <- normalizePath(path, mustWork = FALSE)
  if (!file.exists(normalized)) {
    stop(sprintf("stow(): file does not exist: %s", path), call. = FALSE)
  }
  ext <- tolower(tools::file_ext(normalized))
  reader <- switch(
    ext,
    csv     = "read_csv_auto",
    tsv     = "read_csv_auto",
    parquet = "read_parquet",
    pq      = "read_parquet",
    stop(sprintf("stow(): unsupported file extension '%s'", ext), call. = FALSE)
  )
  escaped <- gsub("'", "''", normalized, fixed = TRUE)
  sql <- sprintf("SELECT * FROM %s('%s')", reader, escaped)
  DBI::dbGetQuery(con, sql)
}

# Server-side CSV/Parquet ingest: CREATE TABLE AS from DuckDB's
# read_csv_auto / read_parquet. No R-side materialization.
#
# Returns the name of the newly-created DuckDB table (`dest_table`
# as passed in). The caller is responsible for hashing, renaming
# to the canonical physical_name, registering in _mr_versions,
# and cleaning up on error.
.mr_ingest_file_to_table <- function(con, path, dest_table) {
  if (any(charToRaw(path) == as.raw(0L))) {
    stop("stow(): path contains a null byte.", call. = FALSE)
  }
  normalized <- normalizePath(path, mustWork = FALSE)
  if (!file.exists(normalized)) {
    stop(sprintf("stow(): file does not exist: %s", path), call. = FALSE)
  }
  ext <- tolower(tools::file_ext(normalized))
  reader <- switch(
    ext,
    csv     = "read_csv_auto",
    tsv     = "read_csv_auto",
    parquet = "read_parquet",
    pq      = "read_parquet",
    stop(sprintf("stow(): unsupported file extension '%s'", ext), call. = FALSE)
  )
  escaped <- gsub("'", "''", normalized, fixed = TRUE)
  sql <- sprintf(
    "CREATE TABLE %s AS SELECT * FROM %s('%s')",
    .mr_quote_ident(dest_table), reader, escaped
  )
  .mr_execute(con, sql)
  invisible(dest_table)
}

# Content-hash an existing DuckDB table by name. Row- and column-order
# independent, type-sensitive.
#
# Algorithm:
#   1. Inspect the table's columns in sorted column-name order (makes the
#      hash invariant to column order).
#   2. Compute a per-row hash via DuckDB HASH() over those columns.
#   3. STRING_AGG the row hashes in sorted row-hash order, separated by
#      '|'. The ORDER BY inside STRING_AGG makes the aggregate
#      row-order invariant (up to 64-bit HASH collisions) while
#      preserving row multiplicity.
#   4. MD5 the aggregate string.
#
# Caveat: the ORDER BY sort key is a 64-bit UBIGINT, so row pairs that
# hash to the same value break the total-order guarantee. Birthday-bound
# collision probability is ~0.03% at 100M distinct rows, acceptable at
# v0.1 scale; a deterministic tiebreaker is tracked in docs/internal/followups.md.
# Type-sensitive: HASH(INTEGER 1) != HASH(DOUBLE 1.0).
#
# An empty table (no rows) hashes on its sorted column names alone.
.mr_hash_duckdb_table <- function(con, table_name) {
  info <- DBI::dbGetQuery(
    con,
    sprintf("PRAGMA table_info(%s)", .mr_quote_ident(table_name))
  )
  cols <- sort(info$name)

  if (length(cols) == 0L) {
    # Table with no columns -- shouldn't happen in practice.
    sql <- "SELECT MD5('empty|') AS h"
    return(DBI::dbGetQuery(con, sql)$h[[1]])
  }

  nrows <- DBI::dbGetQuery(
    con,
    sprintf("SELECT COUNT(*) AS n FROM %s", .mr_quote_ident(table_name))
  )$n[[1]]

  if (nrows == 0L) {
    empty_key <- paste0("empty|", paste(cols, collapse = ","))
    sql <- sprintf("SELECT MD5('%s') AS h", gsub("'", "''", empty_key, fixed = TRUE))
    return(DBI::dbGetQuery(con, sql)$h[[1]])
  }

  cols_sql <- paste(vapply(cols, .mr_quote_ident, character(1)), collapse = ", ")
  sql <- sprintf(
    "SELECT MD5(STRING_AGG(CAST(HASH(%s) AS VARCHAR), '|' ORDER BY HASH(%s))) AS h FROM %s",
    cols_sql, cols_sql, .mr_quote_ident(table_name)
  )
  DBI::dbGetQuery(con, sql)$h[[1]]
}

# Content-hash a data frame by writing it to a transient DuckDB temp
# table and delegating to .mr_hash_duckdb_table. Thin wrapper so the
# materialized-stow path continues to take the same write-then-hash
# shape it had before the refactor.
.mr_hash_frame <- function(con, df) {
  if (nrow(df) == 0L) {
    # Short-circuit: skip the round-trip through DuckDB for an empty
    # frame; replicate the same "empty|<sorted,colnames>" key.
    cols <- sort(names(df))
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
  .mr_hash_duckdb_table(con, tmp)
}
