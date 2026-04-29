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

# User-column order for an append-shape physical table, read from
# DuckDB's catalog. Returns columns in DuckDB's declared order with
# reserved system columns dropped. Falls back to `fallback` (schema
# list order) if the catalog query returns nothing, which shouldn't
# happen but keeps the lazy-write path from faulting if PRAGMA is
# disabled in a future DuckDB build.
.mr_append_user_col_order <- function(con, physical, fallback) {
  info <- tryCatch(
    DBI::dbGetQuery(
      con,
      sprintf("PRAGMA table_info(%s)", .mr_quote_ident(physical))
    ),
    error = function(e) NULL
  )
  if (is.null(info) || nrow(info) == 0L) {
    # The fallback is exactly the silent-failure surface the 2026-04-24
    # PRAGMA-driven rewrite was meant to remove (parsed JSON key order
    # is not guaranteed across jsonlite versions). Surface a warning so
    # any regression that re-routes through the fallback shows up
    # instead of silently misaligning INSERT column order.
    warning(sprintf(
      ".mr_append_user_col_order(): PRAGMA table_info(%s) failed or returned no rows; falling back to schema key order.",
      .mr_quote_ident(physical)
    ), call. = FALSE)
    return(fallback)
  }
  setdiff(info$name, .mr_append_reserved_cols)
}

# Convert a data frame's column types to DuckDB types, returning a
# list(col = type, ...). Used to build the CREATE TABLE and to populate
# schema_json.
.mr_append_frame_types <- function(df) {
  setNames(
    lapply(df, .mr_append_r_to_duckdb_type),
    names(df)
  )
}

# POSIXct -> ISO-8601 UTC so two runs in different session TZs coerce
# identical instants to identical TEXT. Non-POSIXct columns go through
# as.character, which is TZ-independent for Date / numeric / logical.
.mr_append_coerce_to_text <- function(col) {
  if (inherits(col, "POSIXct")) {
    return(format(col, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"))
  }
  as.character(col)
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

# Stamp a row into _mr_append_chunks for the just-committed append.
# Called inside the stow transaction in both the frame and the lazy
# write paths so the chunk record is atomic with the row INSERT.
# After this commits, downstream lookups (chunk_hash <-> run_id,
# latest run for a name, etc.) hit a keyed query against this table
# instead of scanning every `_mr_runs.outputs` JSON.
.mr_append_record_chunk <- function(con, name, run_id, chunk_hash,
                                    rows_appended, started_at) {
  DBI::dbExecute(
    con,
    "INSERT INTO _mr_append_chunks
       (logical_name, run_id, chunk_hash, rows_appended, started_at)
     VALUES (?, ?, ?, ?, ?)",
    params = list(
      name, run_id, as.character(chunk_hash),
      as.integer(rows_appended), started_at
    )
  )
  invisible(NULL)
}

# First-write physical-table DDL. MUST be called BEFORE the caller's
# dbBegin/dbCommit fence: DuckDB auto-commits DDL in standard mode,
# so a CREATE TABLE inside a transaction is not rolled back if the
# subsequent registry INSERT or row INSERT fails. Pulling it outside
# the fence keeps the failure mode clean: either both physical-table
# DDL and registry INSERT succeed, or only the DDL "leaks" — which
# is harmless because CREATE TABLE IF NOT EXISTS is idempotent.
.mr_append_create_physical_table <- function(con, name, frame_types) {
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
  physical
}

# Registry-side first-write: INSERT a row into _mr_append_tables for
# this logical name. MUST be called INSIDE the caller's dbBegin/
# dbCommit fence so the registry stays in sync with the data INSERT.
.mr_append_insert_registry_row <- function(con, name, physical,
                                           frame_types, now) {
  schema_json <- jsonlite::toJSON(frame_types, auto_unbox = TRUE)
  DBI::dbExecute(
    con,
    "INSERT INTO _mr_append_tables
       (logical_name, physical_name, schema_json,
        first_seen, last_seen, row_count, size_bytes)
     VALUES (?, ?, ?, ?, ?, 0, 0)",
    params = list(name, physical, as.character(schema_json), now, now)
  )
  invisible(NULL)
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

  # Pre-fence: registration check + physical-table DDL. The DDL is
  # outside dbBegin/dbCommit because DuckDB auto-commits DDL anyway;
  # leaving it here makes that explicit and prevents a "physical
  # table exists, registry doesn't" inconsistency on a mid-fence
  # failure.
  registered <- DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_append_tables WHERE logical_name = ?",
    params = list(name)
  )
  first_write <- nrow(registered) == 0L
  if (first_write) {
    .mr_append_create_physical_table(con, name, frame_types)
  }

  now <- Sys.time()
  DBI::dbBegin(con)
  tryCatch({
    if (first_write) {
      .mr_append_insert_registry_row(con, name, physical, frame_types, now)
      schema <- frame_types
    } else {
      schema <- .mr_append_reconcile_schema(con, name, registered, value)
    }

    # Apply coercion for any columns where the stored type was cast to TEXT.
    to_insert <- value
    coerce <- attr(schema, "coerce_to_text")
    if (!is.null(coerce)) {
      for (col in coerce) {
        to_insert[[col]] <- .mr_append_coerce_to_text(to_insert[[col]])
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
    .mr_append_record_chunk(
      con, name, run_id, chunk_hash, nrow(value), now
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
  si <- .mr_capture_session_info()
  row <- data.frame(
    step              = step,
    run_id            = run_id,
    inputs            = "[]",
    outputs           = outputs_json,
    started_at        = started_at,
    duration_ms       = 0L,
    status            = "interactive",
    variant_label     = NA_character_,
    hostname          = si$hostname,
    os                = si$os,
    arch              = si$arch,
    r_version         = si$r_version,
    n_cpu             = si$n_cpu,
    total_ram_bytes   = si$total_ram_bytes,
    free_ram_bytes    = si$free_ram_bytes,
    attached_packages = si$attached_packages,
    git_sha           = si$git_sha,
    git_branch        = si$git_branch,
    git_dirty         = si$git_dirty,
    stringsAsFactors  = FALSE
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
    # Restrict to runs that actually wrote to `name`; a run with a
    # matching variant_label that produced a different table would
    # otherwise silently give zero rows.
    latest_run <- DBI::dbGetQuery(
      con,
      sprintf(
        "SELECT run_id
           FROM _mr_runs
          WHERE variant_label = ?
            AND run_id IN (SELECT DISTINCT _mr_run_id FROM %s)
          ORDER BY started_at DESC
          LIMIT 1",
        .mr_quote_ident(physical)),
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

  # Pre-fence: registration check + DDL outside dbBegin/dbCommit (see
  # comment in .mr_append_write_frame for the rationale).
  registered <- DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_append_tables WHERE logical_name = ?",
    params = list(name)
  )
  first_write <- nrow(registered) == 0L
  if (first_write) {
    .mr_append_create_physical_table(con, name, frame_types)
  }

  DBI::dbBegin(con)
  tryCatch({
    if (first_write) {
      .mr_append_insert_registry_row(con, name, physical, frame_types, now)
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

    # Drive INSERT column order from DuckDB's own catalog rather than
    # names(schema), which depends on jsonlite key preservation. Either
    # ordering is correct today (INSERT names columns explicitly), but
    # anchoring to PRAGMA table_info makes the lazy-write path
    # robust to a future jsonlite upgrade reordering parsed keys.
    user_cols <- .mr_append_user_col_order(con, physical, names(schema))
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

    # Rough R-memory-equivalent size estimate for the lazy path:
    # (rows_inserted) x (object.size of one synthesized user-cols row).
    # Matches the frame path's object.size() semantics so the registry's
    # size_bytes counter is comparable across both writers. Proper
    # DuckDB on-disk sizing is tracked as a follow-up.
    per_row_bytes <- if (length(user_cols) > 0L && nrow(zero_head) == 0L) {
      # Build a 1-row frame of the right types from schema and measure.
      sample_row <- as.data.frame(lapply(schema, function(type) {
        switch(type,
          INTEGER   = NA_integer_,
          BIGINT    = NA_real_,
          DOUBLE    = NA_real_,
          VARCHAR   = NA_character_,
          TEXT      = NA_character_,
          BOOLEAN   = NA,
          TIMESTAMP = Sys.time(),
          NA
        )
      }), stringsAsFactors = FALSE)
      as.numeric(utils::object.size(sample_row))
    } else 0
    size_bytes_delta <- rows_inserted * per_row_bytes

    DBI::dbExecute(
      con,
      "UPDATE _mr_append_tables
          SET row_count  = row_count + ?,
              size_bytes = size_bytes + ?,
              last_seen  = ?
        WHERE logical_name = ?",
      params = list(rows_inserted, size_bytes_delta, now, name)
    )
    chunk_hash <- .mr_hash_bytes(charToRaw(sql_body))
    output_entry <- list(
      kind          = "append_table",
      logical_name  = name,
      rows_appended = rows_inserted,
      chunk_hash    = chunk_hash
    )
    .mr_append_record_chunk(
      con, name, run_id, chunk_hash, rows_inserted, now
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

# Scan `_mr_runs.outputs` for append_table entries naming this logical
# name. Returns a data frame with columns run_id, started_at, chunk_hash,
# rows_appended — one row per append (i.e. one row per run that wrote
# to `name`), ordered by started_at ascending. Used by `versions(name)`
# for Shape B names and by the mr_hash() -> run_id reverse lookup.
.mr_append_chunk_entries <- function(con, name) {
  runs <- DBI::dbGetQuery(
    con,
    "SELECT run_id, started_at, outputs
       FROM _mr_runs
      WHERE outputs IS NOT NULL AND outputs <> '[]'
      ORDER BY started_at"
  )
  if (nrow(runs) == 0L) {
    return(data.frame(
      run_id        = character(),
      started_at    = as.POSIXct(character()),
      chunk_hash    = character(),
      rows_appended = integer(),
      stringsAsFactors = FALSE
    ))
  }
  out <- vector("list", nrow(runs))
  for (i in seq_len(nrow(runs))) {
    entries <- tryCatch(
      jsonlite::fromJSON(runs$outputs[i], simplifyVector = FALSE),
      error = function(e) list()
    )
    rid <- character(); hash <- character(); nrows <- integer()
    for (e in entries) {
      if (identical(e$kind, "append_table") &&
          identical(e$logical_name, name)) {
        rid   <- c(rid,   runs$run_id[i])
        hash  <- c(hash,  as.character(e$chunk_hash))
        nrows <- c(nrows, as.integer(e$rows_appended))
      }
    }
    if (length(rid) > 0L) {
      out[[i]] <- data.frame(
        run_id        = rid,
        started_at    = rep(runs$started_at[i], length(rid)),
        chunk_hash    = hash,
        rows_appended = nrows,
        stringsAsFactors = FALSE
      )
    }
  }
  out <- out[!vapply(out, is.null, logical(1))]
  if (length(out) == 0L) {
    return(data.frame(
      run_id        = character(),
      started_at    = as.POSIXct(character()),
      chunk_hash    = character(),
      rows_appended = integer(),
      stringsAsFactors = FALSE
    ))
  }
  do.call(rbind, out)
}

# Resolve a chunk_hash to the run_id that wrote it, for a given Shape B
# logical name. Returns NA_character_ if no match. If the same
# chunk_hash appears for multiple runs (possible when two runs append
# identical content), the most recent run wins.
.mr_append_run_id_for_chunk_hash <- function(con, name, chunk_hash) {
  hits <- DBI::dbGetQuery(
    con,
    "SELECT run_id FROM _mr_append_chunks
      WHERE logical_name = ? AND chunk_hash = ?
      ORDER BY started_at DESC
      LIMIT 1",
    params = list(name, as.character(chunk_hash))
  )
  if (nrow(hits) == 0L) return(NA_character_)
  hits$run_id[1]
}

# Latest run_id that wrote to a Shape B logical name, or NA_character_
# if the name has no appended chunks yet.
.mr_append_latest_run_id <- function(con, name) {
  hits <- DBI::dbGetQuery(
    con,
    "SELECT run_id FROM _mr_append_chunks
      WHERE logical_name = ?
      ORDER BY started_at DESC
      LIMIT 1",
    params = list(name)
  )
  if (nrow(hits) == 0L) return(NA_character_)
  hits$run_id[1]
}

# chunk_hash of a specific run's append on a Shape B logical name, or
# NA_character_ if none. Used by the SQL-launch path to record which
# chunk was read even when the caller didn't pass an explicit mr_hash().
.mr_append_chunk_hash_for_run <- function(con, name, run_id) {
  hits <- DBI::dbGetQuery(
    con,
    "SELECT chunk_hash FROM _mr_append_chunks
      WHERE logical_name = ? AND run_id = ?
      ORDER BY started_at
      LIMIT 1",
    params = list(name, run_id)
  )
  if (nrow(hits) == 0L) return(NA_character_)
  hits$chunk_hash[1]
}

# Create (idempotently) a read-only DuckDB view projecting the user
# columns of a Shape B logical name's physical append table, filtered
# to a single run's rows. Returns the view's physical name. Used by
# SQL-launch @inputs substitution so that bodies like `FROM src` can
# reference a run-filtered slice without R-side dbplyr staging.
.mr_ensure_append_view <- function(con, name, run_id) {
  reg <- DBI::dbGetQuery(
    con,
    "SELECT physical_name, schema_json FROM _mr_append_tables WHERE logical_name = ?",
    params = list(name)
  )
  if (nrow(reg) == 0L) {
    stop(sprintf(
      "modelrunnR internal: no _mr_append_tables row for '%s'.", name
    ), call. = FALSE)
  }
  physical <- reg$physical_name[1]
  schema   <- jsonlite::fromJSON(reg$schema_json[1], simplifyVector = FALSE)
  user_cols <- paste(
    vapply(names(schema), .mr_quote_ident, character(1)),
    collapse = ", "
  )
  # Name the view deterministically: reusable across calls, and the
  # run_id suffix makes it unique per rebind so the SQL-launch body
  # hash differs across rebinds (consistent with Shape A's content-hash
  # physical names driving staleness).
  view_name <- sprintf("%s__run__%s", name,
                       gsub("[^0-9A-Za-z_]", "_", run_id))
  .mr_execute(
    con,
    sprintf(
      "CREATE OR REPLACE VIEW %s AS SELECT %s FROM %s WHERE \"_mr_run_id\" = %s",
      .mr_quote_ident(view_name),
      user_cols,
      .mr_quote_ident(physical),
      DBI::dbQuoteLiteral(con, run_id)
    )
  )
  view_name
}
