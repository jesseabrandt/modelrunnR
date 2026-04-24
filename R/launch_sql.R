## SQL launches.
##
## A SQL step is a single SELECT (or WITH ... SELECT) executed against
## the modelrunnR DuckDB connection and registered as a versioned
## `_mr_versions` row. Default is `kind = "view"` -- the SELECT body
## becomes a CREATE OR REPLACE VIEW with the rendered SQL as the
## content_hash input. With `materialize = TRUE`, the body is wrapped
## as CREATE OR REPLACE TABLE instead and hashed by row contents (same
## machinery as lazy stow).
##
## Two new dispatch forms on `launch()`:
##   - File mode:   first argument is a path ending in .sql (case-
##                  insensitive).
##   - Inline mode: first argument is a call to mr_sql("...").
##
## Both routes go through .mr_launch_sql(); see launch.R for the
## dispatch ladder.

# Top-level driver invoked from launch() once dispatch has resolved
# the call as a SQL launch.
#
# Parameters mirror launch():
#   src_kind:   "file" or "inline"
#   path_or_body: file path (file mode) or SQL string (inline mode)
#   materialize:  logical; FALSE = view, TRUE = table
#   rebind:       resolved (named) rebind list, name -> content_hash
#   provenance:   resolved-rebinds JSON-shaped list (for run row); may
#                 be empty list().
#   external_inputs_resolved: as returned by .mr_resolve_external_inputs()
#   label, force, duckdb_seed: same semantics as R-mode launch().
#
# Returns the run row data.frame invisibly.
.mr_launch_sql <- function(src_kind, path_or_body, materialize,
                           rebind, provenance,
                           external_inputs_resolved,
                           label, force, duckdb_seed,
                           skip_on_fresh) {
  stopifnot(src_kind %in% c("file", "inline"))

  # 1. Read raw bytes (file mode) or take the body string directly.
  if (src_kind == "file") {
    if (!file.exists(path_or_body)) {
      stop(sprintf("launch(): script not found: %s", path_or_body),
           call. = FALSE)
    }
    step      <- normalizePath(path_or_body, mustWork = TRUE)
    code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
  } else {
    code_body <- path_or_body
    expr_hash <- .mr_hash_bytes(charToRaw(code_body))
    step      <- sprintf("<inline:sql:%s>", substr(expr_hash, 1L, 12L))
  }

  # 2. Parse + validate. Errors here happen *before* any DB write.
  parsed <- .mr_parse_sql_header(code_body)
  output_name <- parsed$output
  if (is.null(output_name)) {
    if (src_kind == "file") {
      output_name <- tools::file_path_sans_ext(basename(step))
    } else {
      stop(
        "launch(): inline SQL requires '@output: <name>' in the header.",
        call. = FALSE
      )
    }
  }
  .mr_validate_name(output_name, context = "launch")

  # 3. Cross-check rebind against declared @inputs. Spec rule: every
  #    rebind name must appear in @inputs (otherwise the substitution
  #    would silently no-op).
  for (nm in names(rebind)) {
    if (!(nm %in% parsed$inputs)) {
      stop(sprintf(
        "launch(rebind=): '%s' is not declared in @inputs (%s).",
        nm, paste(parsed$inputs, collapse = ", ")
      ), call. = FALSE)
    }
  }

  # 4. Resolve @inputs to (name, content_hash) pairs and build a
  #    name -> physical_name map for substitution. Names rebound by the
  #    caller resolve to the rebound version; otherwise resolve latest.
  con <- .mr_get_connection()
  inputs_pairs <- list()
  physical_for <- list()
  for (nm in parsed$inputs) {
    .mr_validate_name(nm, context = "launch")
    # Existence pre-check with the spec-mandated wording (§6.3) -- the
    # generic resolver error ("no value stowed under '<name>'") is less
    # actionable for the SQL launch path.
    target_hash <- rebind[[nm]]
    if (is.null(target_hash)) {
      exists_row <- DBI::dbGetQuery(
        con,
        "SELECT 1 FROM _mr_versions WHERE logical_name = ? LIMIT 1",
        params = list(nm)
      )
      if (nrow(exists_row) == 0L) {
        stop(sprintf(
          "launch(): @inputs references '%s' but no stowed value exists. Did you stow() or ingest() it first?",
          nm
        ), call. = FALSE)
      }
    }
    row <- if (is.null(target_hash)) {
      .mr_resolve_version(con, nm, NULL, NULL, NULL)
    } else {
      .mr_resolve_version(con, nm, target_hash, NULL, NULL)
    }
    if (!(row$kind %in% c("table", "view"))) {
      stop(sprintf(
        "launch(): @inputs '%s' resolves to a %s; SQL inputs must be table or view.",
        nm, row$kind
      ), call. = FALSE)
    }
    inputs_pairs[[length(inputs_pairs) + 1L]] <-
      list(name = nm, hash = row$content_hash)
    physical_for[[nm]] <- row$physical_name
  }

  # 5. Render the body: word-boundary substitution of input names ->
  #    physical names. Skipped for un-rebound names whose physical name
  #    matches the logical name (case where logical and physical
  #    coincide is unreachable given .mr_physical_name's hash suffix,
  #    but the substitution is a no-op then anyway).
  rendered_body <- parsed$body
  for (nm in parsed$inputs) {
    pat <- paste0("\\b", .mr_regex_escape(nm), "\\b")
    rendered_body <- gsub(
      pat, .mr_quote_ident(physical_for[[nm]]), rendered_body, perl = TRUE
    )
  }

  # 6. code_hash for the run row. SQL has no transitively-sourced helpers
  #    (helpers always []), so this reuses the R-mode helper for the same
  #    file/inline split. Crucially the input goes through the same
  #    pipeline that `.mr_check_code_hash*` uses to recompute, so a
  #    re-run of the same body produces the same hash and the staleness
  #    check returns fresh. Rebind-driven physical-name changes show up
  #    on the inputs arm, not here.
  run_code_hash <- if (src_kind == "file") {
    .mr_code_hash(step, list())
  } else {
    .mr_code_hash_inline(code_body, list())
  }

  # 7. Pre-flight staleness via the run-row history for this step under
  #    this label. Reuses the R-mode .mr_is_stale() machinery; helpers
  #    are vacuously [] for SQL steps.
  staleness <- .mr_is_stale(step, variant_label = label)
  will_skip <- !staleness$stale && !isTRUE(force) && skip_on_fresh
  .mr_print_staleness(step, staleness, will_skip = will_skip)

  run_id     <- .mr_new_run_id()
  started_at <- Sys.time()
  start_secs <- as.numeric(started_at)

  if (will_skip) {
    return(invisible(.mr_record_skipped_fresh_sql(
      step               = step,
      run_id             = run_id,
      started_at         = started_at,
      external_inputs    = external_inputs_resolved,
      code_body          = code_body,
      label              = label,
      provenance         = provenance,
      duckdb_seed        = duckdb_seed
    )))
  }

  # 8. Apply duckdb_seed before the DDL fires.
  if (!is.null(duckdb_seed)) {
    DBI::dbExecute(con, "SELECT setseed(?)", params = list(duckdb_seed))
  }

  # 9. Namespace guard for the chosen kind, then register.
  new_kind <- if (isTRUE(materialize)) "table" else "view"
  .mr_guard_namespace(output_name, shape = "A", new_kind = new_kind, context = "launch")

  status  <- "success"
  err_obj <- NULL
  output_hash <- NA_character_
  tryCatch({
    output_hash <- if (isTRUE(materialize)) {
      .mr_register_sql_table(output_name, rendered_body)
    } else {
      .mr_register_view(output_name, rendered_body)
    }
  }, error = function(e) {
    status  <<- "error"
    err_obj <<- e
  })

  duration_ms <- as.integer(round((as.numeric(Sys.time()) - start_secs) * 1000))

  outputs_pairs <- if (status == "success") {
    list(list(name = output_name, hash = output_hash))
  } else {
    list()
  }

  # 10. Auto-propagation: a SQL launch can inherit a label from its
  #     resolved @inputs the same way an R launch does. Skipped on
  #     status="error" so a failed registration doesn't drag a label
  #     onto an unproductive run row.
  propagation_source <- NULL
  if (status == "success" && is.na(label) && length(inputs_pairs) > 0L) {
    prop <- .mr_propagate_label(con, inputs_pairs)
    if (!is.na(prop)) {
      label <- unclass(prop)
      propagation_source <- .mr_first_input_producing(
        inputs_pairs, con, label
      )
    } else if (!is.null(attr(prop, "disagreement"))) {
      disagreement <- attr(prop, "disagreement")
      warning(sprintf(
        "ambiguous upstream variants: %s. Running without a label; pass label= to disambiguate.",
        paste(sprintf("%s -> %s", names(disagreement), unlist(disagreement)),
              collapse = ", ")
      ), call. = FALSE)
    }
  }

  run_row <- .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = inputs_pairs,
    outputs         = outputs_pairs,
    started_at      = started_at,
    duration_ms     = duration_ms,
    status          = status,
    code_hash       = run_code_hash,
    external_inputs = external_inputs_resolved,
    helpers         = list(),
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = provenance
  )

  .mr_print_timing_summary(
    step,
    duration_ms,
    status,
    n_grabs            = length(inputs_pairs),
    n_stows            = length(outputs_pairs),
    variant_label      = label,
    propagation_source = propagation_source
  )

  if (!is.null(err_obj) && !isTRUE(.mr_state$batch_active)) stop(err_obj)
  invisible(run_row)
}

# Register a SQL view as a versioned `_mr_versions` row. The rendered
# SQL is the content_hash input (views have no rows to hash; the SQL
# text *is* the identity).
.mr_register_view <- function(name, rendered_sql) {
  con <- .mr_get_connection()
  content_hash  <- .mr_hash_bytes(charToRaw(rendered_sql))
  physical_name <- .mr_physical_name(name, content_hash)

  existing <- .mr_get_version_row(con, name, content_hash)
  now <- Sys.time()

  DBI::dbBegin(con)
  tryCatch({
    if (nrow(existing) == 0L) {
      .mr_execute(
        con,
        sprintf(
          "CREATE OR REPLACE VIEW %s AS %s",
          .mr_quote_ident(physical_name), rendered_sql
        )
      )
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_versions
           (logical_name, content_hash, physical_name, kind,
            first_seen, last_seen, size_bytes, storage_location, source_sql)
         VALUES (?, ?, ?, 'view', ?, ?, NULL, NULL, ?)",
        params = list(name, content_hash, physical_name, now, now, rendered_sql)
      )
      .mr_refresh_latest_view(con, name)
    } else {
      DBI::dbExecute(
        con,
        "UPDATE _mr_versions
           SET last_seen = ?
         WHERE logical_name = ? AND content_hash = ?",
        params = list(now, name, content_hash)
      )
    }
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  content_hash
}

# Materialize a SQL body as a versioned table. Hashed by row contents
# (same machinery as .mr_stow_lazy); source_sql captures the rendered
# SQL informationally.
.mr_register_sql_table <- function(name, rendered_sql) {
  con <- .mr_get_connection()

  staging <- paste0(
    "_mr_tmp_sql_",
    paste(sample(c(0:9, letters), 10, replace = TRUE), collapse = "")
  )
  .mr_execute(
    con,
    sprintf(
      "CREATE TABLE %s AS %s",
      .mr_quote_ident(staging), rendered_sql
    )
  )
  staging_alive <- TRUE
  on.exit(
    if (staging_alive) try(.mr_drop_table(con, staging), silent = TRUE),
    add = TRUE
  )

  content_hash  <- .mr_hash_duckdb_table(con, staging)
  physical_name <- .mr_physical_name(name, content_hash)

  existing <- .mr_get_version_row(con, name, content_hash)
  now <- Sys.time()

  DBI::dbBegin(con)
  tryCatch({
    if (nrow(existing) == 0L) {
      .mr_execute(
        con,
        sprintf(
          "ALTER TABLE %s RENAME TO %s",
          .mr_quote_ident(staging), .mr_quote_ident(physical_name)
        )
      )
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_versions
           (logical_name, content_hash, physical_name, kind,
            first_seen, last_seen, size_bytes, storage_location, source_sql)
         VALUES (?, ?, ?, 'table', ?, ?, 0, NULL, ?)",
        params = list(name, content_hash, physical_name, now, now, rendered_sql)
      )
      .mr_refresh_latest_view(con, name)
    } else {
      DBI::dbExecute(
        con,
        "UPDATE _mr_versions
           SET last_seen = ?
         WHERE logical_name = ? AND content_hash = ?",
        params = list(now, name, content_hash)
      )
    }
    DBI::dbCommit(con)
    staging_alive <<- FALSE
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  content_hash
}

# Skip-on-fresh row for a SQL launch: no rendering happens, no view
# created, run row records what would have been bound to.
.mr_record_skipped_fresh_sql <- function(step, run_id, started_at,
                                         external_inputs, code_body,
                                         label, provenance, duckdb_seed) {
  con <- .mr_get_connection()
  if (is.na(label)) {
    prior <- DBI::dbGetQuery(
      con,
      "SELECT variant_label FROM _mr_runs
        WHERE step = ?
        ORDER BY started_at DESC LIMIT 1",
      params = list(step)
    )
    if (nrow(prior) > 0L && !is.na(prior$variant_label[1])) {
      label <- prior$variant_label[1]
    }
  }
  prior_hash <- DBI::dbGetQuery(
    con,
    "SELECT code_hash FROM _mr_runs
      WHERE step = ?
      ORDER BY started_at DESC LIMIT 1",
    params = list(step)
  )
  code_hash <- if (nrow(prior_hash) == 0L) NA_character_ else prior_hash$code_hash[1]

  .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = list(),
    outputs         = list(),
    started_at      = started_at,
    duration_ms     = 0L,
    status          = "skipped_fresh",
    code_hash       = code_hash,
    external_inputs = external_inputs,
    helpers         = list(),
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = provenance
  )
}

# Regex-escape a string so it can be used as a literal identifier in a
# regex pattern (used by the @inputs -> physical-name substitution).
.mr_regex_escape <- function(s) {
  gsub("([.\\\\+*?\\[\\^\\]$(){}=!<>|:\\-])", "\\\\\\1", s, perl = TRUE)
}
