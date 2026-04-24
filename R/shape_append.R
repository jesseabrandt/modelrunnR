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
  if (inherits(col, "integer64")) return("BIGINT")
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

# Top-level append for materialized frames. When called inside an active
# recording context, stamps rows with the launch's run_id / variant_label
# and records the append as a structured output on the recording. Outside
# a launch, mints a synthetic `<interactive:TS>` run row (matching the
# Shape A / ingest pattern in R/interactive.R) so every Shape B row still
# has a real run_id, grab()'s "latest run" rule stays coherent, and later
# launches that grab() the value get the same reproducibility warning
# that artifact / ingest inputs already trigger.
.mr_append_write_frame <- function(name, value) {
  run_id      <- .mr_recording_run_id()
  interactive <- is.null(run_id) || is.na(run_id)
  if (interactive) {
    run_id <- .mr_new_run_id()
    label  <- NA_character_
  } else {
    label <- .mr_recording_variant_label()
    if (is.null(label)) label <- NA_character_
  }

  .mr_append_guard_reserved_cols(name, value)

  if (.mr_has_nondefault_rownames(value)) {
    warning(
      "stow(): row names are not persisted by the DuckDB backend. ",
      "Convert to a column (e.g. with `tibble::rownames_to_column()`) ",
      "if you need them.",
      call. = FALSE
    )
  }

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
      schema <- frame_types
    } else {
      schema <- .mr_append_reconcile_schema(con, name, registered, value)
    }

    # Apply coercion for any columns where the stored type was cast to TEXT.
    to_insert <- value
    coerce <- attr(schema, "coerce_to_text")
    if (!is.null(coerce)) {
      # NOTE: as.character() on POSIXct is session-TZ-dependent; coercion
      # result depends on Sys.timezone() at stow() call time. Other types
      # (Date, logical, numeric) are TZ-independent.
      for (col in coerce) {
        to_insert[[col]] <- as.character(to_insert[[col]])
      }
    }
    # Task 6 path: fill schema-known columns absent from incoming frame
    # with NA. Independent of the coercion loop above.
    for (col in setdiff(names(schema), names(to_insert))) {
      to_insert[[col]] <- NA
    }
    # Stamp system columns and insert. `dbAppendTable` matches by name
    # so column order in `to_insert` is irrelevant.
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
    chunk_hash <- .mr_append_row_hash(value)
    output_entry <- list(
      kind          = "append_table",
      logical_name  = name,
      rows_appended = nrow(value),
      chunk_hash    = chunk_hash
    )
    if (interactive) {
      .mr_write_interactive_run_row(con, run_id, list(output_entry), now)
    }
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  if (!interactive) {
    .mr_record_structured_output(output_entry)
  }
  invisible(chunk_hash)
}

# Insert a synthetic `<interactive:TS>` _mr_runs row for bare stow()
# writes of tabular values (i.e. called outside any launch). Mirrors the
# Shape A / ingest pattern in R/interactive.R so downstream launches
# that grab() the value get the existing reproducibility warning.
# Called inside the caller's transaction; outputs JSON is passed in
# directly since no recording context is active to flush at run end.
.mr_write_interactive_run_row <- function(con, run_id, outputs_entries,
                                          started_at = Sys.time()) {
  outputs_json <- if (length(outputs_entries) == 0L) {
    "[]"
  } else {
    as.character(jsonlite::toJSON(outputs_entries, auto_unbox = TRUE))
  }
  step <- sprintf("<interactive:%s>",
                  format(started_at, "%Y-%m-%d %H:%M:%OS3"))
  row <- data.frame(
    step          = step,
    run_id        = run_id,
    inputs        = "[]",
    outputs       = outputs_json,
    started_at    = started_at,
    duration_ms   = 0L,
    status        = "interactive",
    variant_label = NA_character_,
    stringsAsFactors = FALSE
  )
  DBI::dbAppendTable(con, "_mr_runs", row)
  invisible(run_id)
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

# Reconcile the incoming frame's columns against the stored schema.
# Returns the (possibly extended) stored schema list. Performs any
# ALTER TABLE ADD COLUMN operations and updates _mr_append_tables's
# schema_json inside the caller's transaction.
.mr_append_reconcile_schema <- function(con, name, registered_row, value) {
  physical <- registered_row$physical_name[1]
  schema   <- jsonlite::fromJSON(registered_row$schema_json[1], simplifyVector = FALSE)
  incoming_types <- .mr_append_frame_types(value)

  added   <- setdiff(names(incoming_types), names(schema))
  missing <- setdiff(names(schema), names(incoming_types))

  if (length(added) > 0L) {
    warning(sprintf(
      "stow('%s'): extending schema with new column%s: %s",
      name,
      if (length(added) == 1L) "" else "s",
      paste(added, collapse = ", ")
    ), call. = FALSE)
    for (col in added) {
      type <- incoming_types[[col]]
      .mr_execute(
        con,
        sprintf("ALTER TABLE %s ADD COLUMN %s %s",
                .mr_quote_ident(physical),
                .mr_quote_ident(col),
                type)
      )
      schema[[col]] <- type
    }
  }

  if (length(missing) > 0L) {
    message(sprintf(
      "stow('%s'): incoming data missing column%s %s; inserted as NULL",
      name,
      if (length(missing) == 1L) "" else "s",
      paste(sprintf("'%s'", missing), collapse = ", ")
    ))
  }

  # Type-conflict resolution — coerce offending column to TEXT
  # (spec §4.1 option a). Cast the stored column and coerce the
  # incoming column; update schema_json.
  common <- intersect(names(schema), names(incoming_types))
  conflicts <- common[vapply(common,
    function(c) !identical(schema[[c]], incoming_types[[c]]),
    logical(1))]

  for (col in conflicts) {
    warning(sprintf(
      "stow('%s'): type conflict on column '%s' (stored %s, incoming %s); coercing column to TEXT.",
      name, col, schema[[col]], incoming_types[[col]]
    ), call. = FALSE)
    .mr_execute(
      con,
      sprintf(
        "ALTER TABLE %s ALTER COLUMN %s SET DATA TYPE TEXT USING CAST(%s AS TEXT)",
        .mr_quote_ident(physical),
        .mr_quote_ident(col),
        .mr_quote_ident(col)
      )
    )
    schema[[col]] <- "TEXT"
  }

  # Attach conflicts as an attribute so the caller can coerce the
  # incoming data frame before insert.
  if (length(conflicts) > 0L) {
    attr(schema, "coerce_to_text") <- conflicts
  }

  if (length(added) > 0L || length(conflicts) > 0L) {
    schema_json <- jsonlite::toJSON(schema, auto_unbox = TRUE)
    DBI::dbExecute(
      con,
      "UPDATE _mr_append_tables SET schema_json = ? WHERE logical_name = ?",
      params = list(as.character(schema_json), name)
    )
  }

  schema
}

# Stable, row-order-independent hash of the rows this call contributed.
# Not user-facing; used in _mr_runs.outputs provenance (spec §8).
.mr_append_row_hash <- function(value) {
  .mr_hash_bytes(serialize(value[do.call(order, value), , drop = FALSE], NULL))
}

# Reader for Shape B. Returns a dbplyr lazy tbl filtered per the
# caller's intent.
#
# Filter semantics:
#   - run = <id>      -> that run only. System cols stripped.
#   - run = "all"     -> every row, all runs. System cols surfaced as
#                        user-facing `run_id` / `variant_label`.
#   - variant = <lbl> -> latest run with that label. System cols stripped.
#   - (default)       -> latest run that wrote this name. System cols
#                        stripped. "Latest" = most recent `started_at`
#                        across runs whose `run_id` appears in the
#                        physical table. Matches the exploratory
#                        workflow: grab() pulls one coherent snapshot,
#                        not the whole cross-run pile.
.mr_append_read <- function(name, run = NULL, variant = NULL) {
  con <- .mr_get_connection()
  physical <- .mr_append_physical_name(name)
  base <- dplyr::tbl(con, physical)

  if (identical(run, "all")) {
    return(base |>
      dplyr::rename(
        run_id        = "_mr_run_id",
        variant_label = "_mr_variant_label"
      ))
  }

  if (!is.null(run)) {
    base <- base |>
      dplyr::filter(.data[["_mr_run_id"]] == !!run) |>
      dplyr::select(-dplyr::any_of(c("_mr_run_id", "_mr_variant_label")))
    return(base)
  }

  if (!is.null(variant)) {
    latest_run <- DBI::dbGetQuery(
      con,
      "SELECT run_id
         FROM _mr_runs
        WHERE variant_label = ?
        ORDER BY started_at DESC
        LIMIT 1",
      params = list(variant)
    )
    if (nrow(latest_run) == 0L) {
      stop(sprintf(
        "grab(): no run with variant '%s' has produced '%s'.", variant, name
      ), call. = FALSE)
    }
    rid <- latest_run$run_id[1]
    base <- base |>
      dplyr::filter(.data[["_mr_run_id"]] == !!rid) |>
      dplyr::select(-dplyr::any_of(c("_mr_run_id", "_mr_variant_label")))
    return(base)
  }

  # Default: the latest run that wrote this name. Join the table's
  # distinct _mr_run_ids against _mr_runs to pick the one with the
  # largest `started_at`.
  latest <- DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT r.run_id
         FROM _mr_runs r
         JOIN (SELECT DISTINCT _mr_run_id AS rid FROM %s) a
           ON r.run_id = a.rid
        ORDER BY r.started_at DESC
        LIMIT 1",
      .mr_quote_ident(physical)
    )
  )
  if (nrow(latest) == 0L) {
    # No run has contributed rows yet — return an empty, system-col-
    # stripped tbl so downstream collect() gives zero rows with the
    # user schema.
    return(base |>
      dplyr::filter(FALSE) |>
      dplyr::select(-dplyr::any_of(c("_mr_run_id", "_mr_variant_label"))))
  }
  rid <- latest$run_id[1]
  base |>
    dplyr::filter(.data[["_mr_run_id"]] == !!rid) |>
    dplyr::select(-dplyr::any_of(c("_mr_run_id", "_mr_variant_label")))
}

.mr_append_write_lazy <- function(name, value) {
  run_id      <- .mr_recording_run_id()
  interactive <- is.null(run_id) || is.na(run_id)
  if (interactive) {
    run_id <- .mr_new_run_id()
    label  <- NA_character_
  } else {
    label <- .mr_recording_variant_label()
    if (is.null(label)) label <- NA_character_
  }

  con <- .mr_get_connection()
  remote <- dbplyr::remote_con(value)
  if (!identical(remote, con)) {
    stop(
      "stow(): lazy tbl is bound to a different DBI connection; ",
      "call dplyr::collect() first and stow the materialized result.",
      call. = FALSE
    )
  }

  # Peek the lazy tbl's column types via a zero-row collect — lets us
  # reuse the reconciliation path without materializing the full result
  # twice.
  zero_head <- value |> head(0) |> dplyr::collect()
  .mr_append_guard_reserved_cols(name, zero_head)

  frame_types <- .mr_append_frame_types(zero_head)
  sql_body <- as.character(dbplyr::sql_render(value))
  physical <- .mr_append_physical_name(name)
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
      schema <- frame_types
    } else {
      schema <- .mr_append_reconcile_schema(con, name, registered, zero_head)
      coerce <- attr(schema, "coerce_to_text")
      if (!is.null(coerce)) {
        stop(sprintf(
          "stow(<lazy tbl>, '%s'): type conflict on column(s) %s; lazy-path coercion deferred to v0.2. Collect() and stow the materialized frame.",
          name, paste(coerce, collapse = ", ")
        ), call. = FALSE)
      }
    }

    user_cols <- names(schema)
    insert_cols <- paste(c(
      vapply(user_cols, .mr_quote_ident, character(1)),
      "\"_mr_run_id\"", "\"_mr_variant_label\""
    ), collapse = ", ")
    select_user <- paste(
      vapply(user_cols, .mr_quote_ident, character(1)),
      collapse = ", "
    )
    sql <- sprintf(
      "INSERT INTO %s (%s) SELECT %s, %s, %s FROM (%s) AS _src",
      .mr_quote_ident(physical),
      insert_cols,
      select_user,
      DBI::dbQuoteLiteral(con, run_id),
      if (is.na(label)) "NULL" else DBI::dbQuoteLiteral(con, as.character(label)),
      sql_body
    )
    rows_inserted <- DBI::dbExecute(con, sql)

    DBI::dbExecute(
      con,
      "UPDATE _mr_append_tables
          SET row_count = row_count + ?, last_seen = ?
        WHERE logical_name = ?",
      params = list(rows_inserted, now, name)
    )
    chunk_hash <- .mr_hash_bytes(charToRaw(sql_body))
    output_entry <- list(
      kind          = "append_table",
      logical_name  = name,
      rows_appended = rows_inserted,
      chunk_hash    = chunk_hash
    )
    if (interactive) {
      .mr_write_interactive_run_row(con, run_id, list(output_entry), now)
    }
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  if (!interactive) {
    .mr_record_structured_output(output_entry)
  }
  invisible(chunk_hash)
}
