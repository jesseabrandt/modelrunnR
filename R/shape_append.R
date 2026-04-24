## Shape B — run-indexed append log.
##
## Per spec §1 / §3:
##   - One physical table per logical name: <logical>__append.
##   - Two system columns appended to user columns: _mr_run_id,
##     _mr_variant_label.
##   - Registered in _mr_append_tables; the schema_json field records
##     the column -> type map of the CURRENT user-facing schema (system
##     columns excluded).

.mr_append_physical_name <- function(name) {
  paste0(name, "__append")
}

.mr_append_reserved_cols <- c("_mr_run_id", "_mr_variant_label")

# Convert a data frame's column types to DuckDB types, returning a
# list(col = type, ...). Used to build the CREATE TABLE and to populate
# schema_json.
.mr_append_frame_types <- function(df) {
  setNames(
    lapply(df, .mr_append_r_to_duckdb_type),
    names(df)
  )
}

.mr_append_r_to_duckdb_type <- function(col) {
  if (is.integer(col))   return("INTEGER")
  if (is.numeric(col))   return("DOUBLE")
  if (is.logical(col))   return("BOOLEAN")
  if (inherits(col, "POSIXct")) return("TIMESTAMP")
  if (inherits(col, "Date"))    return("DATE")
  if (is.character(col)) return("TEXT")
  if (is.factor(col))    return("TEXT")
  "TEXT"
}

# First-write path: create the physical table with user columns +
# system columns, insert the row, register in _mr_append_tables.
.mr_append_ensure_table <- function(con, name, frame_types) {
  physical <- .mr_append_physical_name(name)
  cols <- c(
    vapply(names(frame_types),
           function(c) sprintf("%s %s", .mr_quote_ident(c), frame_types[[c]]),
           character(1)),
    "_mr_run_id TEXT",
    "_mr_variant_label TEXT"
  )
  .mr_execute(
    con,
    sprintf("CREATE TABLE IF NOT EXISTS %s (%s)",
            .mr_quote_ident(physical),
            paste(cols, collapse = ", "))
  )
  schema_json <- jsonlite::toJSON(frame_types, auto_unbox = TRUE)
  now <- Sys.time()
  DBI::dbExecute(
    con,
    "INSERT INTO _mr_append_tables
       (logical_name, physical_name, schema_json,
        first_seen, last_seen, row_count, size_bytes)
     VALUES (?, ?, ?, ?, ?, 0, 0)",
    params = list(name, physical, as.character(schema_json), now, now)
  )
  physical
}

# Top-level append for materialized frames. Caller MUST be inside an
# active recording context (.mr_start_recording) so run_id / variant_label
# are available.
.mr_append_write_frame <- function(name, value) {
  run_id <- .mr_recording_run_id()
  if (is.null(run_id) || is.na(run_id)) {
    stop(
      "stow(): append writes require an active launch() context; ",
      "stow() outside launch() is not supported for data frames in v0.1.",
      call. = FALSE
    )
  }
  label <- .mr_recording_variant_label()
  if (is.null(label)) label <- NA_character_

  .mr_append_guard_reserved_cols(name, value)

  con <- .mr_get_connection()
  physical <- .mr_append_physical_name(name)
  frame_types <- .mr_append_frame_types(value)

  now <- Sys.time()
  DBI::dbBegin(con)
  tryCatch({
    registered <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_append_tables WHERE logical_name = ?",
      params = list(name)
    )
    if (nrow(registered) == 0L) {
      .mr_append_ensure_table(con, name, frame_types)
    } else {
      # Reconciliation (columns added / dropped / type conflict) lands
      # in a subsequent task. First-cut behavior: require exact schema
      # match. Reconciliation will relax this.
      .mr_append_require_schema_match(registered, value)
    }

    # Stamp system columns and insert. `dbAppendTable` matches by name
    # so column order in `value` is irrelevant.
    to_insert <- value
    to_insert[["_mr_run_id"]]         <- run_id
    to_insert[["_mr_variant_label"]]  <- label
    DBI::dbAppendTable(con, physical, to_insert)

    size_bytes <- as.numeric(object.size(value))
    DBI::dbExecute(
      con,
      "UPDATE _mr_append_tables
          SET row_count  = row_count + ?,
              size_bytes = size_bytes + ?,
              last_seen  = ?
        WHERE logical_name = ?",
      params = list(nrow(value), size_bytes, now, name)
    )
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  chunk_hash <- .mr_append_row_hash(value)
  .mr_record_write(name, chunk_hash)
  invisible(chunk_hash)
}

.mr_append_guard_reserved_cols <- function(name, value) {
  conflict <- intersect(colnames(value), .mr_append_reserved_cols)
  if (length(conflict) > 0L) {
    stop(sprintf(
      "stow('%s'): column%s %s %s reserved; rename before stowing.",
      name,
      if (length(conflict) == 1L) "" else "s",
      paste(sprintf("'%s'", conflict), collapse = ", "),
      if (length(conflict) == 1L) "is" else "are"
    ), call. = FALSE)
  }
  invisible(NULL)
}

# Placeholder — tightened in the schema-drift task.
.mr_append_require_schema_match <- function(registered_row, value) {
  schema <- jsonlite::fromJSON(registered_row$schema_json[1], simplifyVector = FALSE)
  incoming_cols <- names(value)
  known_cols    <- names(schema)
  if (!setequal(incoming_cols, known_cols)) {
    stop(sprintf(
      "stow(): incoming columns {%s} do not match stored schema {%s}. Schema reconciliation not yet implemented.",
      paste(incoming_cols, collapse = ", "),
      paste(known_cols,    collapse = ", ")
    ), call. = FALSE)
  }
  invisible(NULL)
}

# Stable, row-order-independent hash of the rows this call contributed.
# Not user-facing; used in _mr_runs.outputs provenance (spec §8).
.mr_append_row_hash <- function(value) {
  .mr_hash_bytes(serialize(value[do.call(order, value), , drop = FALSE], NULL))
}
