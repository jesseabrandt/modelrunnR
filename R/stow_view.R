## View-shape stow: dbplyr lazy expression -> CREATE OR REPLACE VIEW.
##
## Hashing follows the precedent set by .mr_register_view() in
## launch_sql.R: the rendered SQL text is the content_hash input. View
## identity therefore drifts when (a) the user changes the lazy
## expression or (b) an upstream input's physical name drifts (which
## happens for versioned-shape inputs but not for append-shape inputs).
## See TODO.md "Surfaced 2026-05-01" for the staleness weak spot on
## append-shape sources.

# Scan a rendered SQL string for tokens that match physical names
# registered in `_mr_versions` or `_mr_append_tables`. Returns a list
# of (name, hash) pairs. Errors if no managed names are found ("strict"
# input resolution: a view-stow with no upstream provenance is almost
# certainly a user mistake).
#
# Detection is lexical -- tokenizes on word characters and matches
# against the registries. The two registries have disjoint physical-
# name conventions (`name__hex_hash` for versioned, `name__append` for
# append) so a token can only match one or the other. False positives
# would require a user to have a string literal in the SQL whose value
# coincides with a physical name; unlikely but acknowledged.
.mr_sniff_view_inputs <- function(con, rendered_sql) {
  tokens <- unique(regmatches(
    rendered_sql,
    gregexpr("[A-Za-z_][A-Za-z_0-9]*", rendered_sql)
  )[[1]])
  if (length(tokens) == 0L) {
    stop(
      "stow(shape = 'view'): no modelrunnR-managed inputs found in expression. ",
      "Lazy expressions for view-stow must derive from grab().",
      call. = FALSE
    )
  }

  # Render the IN-list inline. DuckDB has issues with vector-bound IN
  # via DBI parameterization in some versions; quote each token defensively.
  quote_str <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
  in_list <- paste(vapply(tokens, quote_str, character(1)), collapse = ", ")

  versioned <- DBI::dbGetQuery(con, sprintf(
    "SELECT physical_name, logical_name, content_hash
       FROM _mr_versions
      WHERE physical_name IN (%s)", in_list
  ))
  appended <- DBI::dbGetQuery(con, sprintf(
    "SELECT physical_name, logical_name
       FROM _mr_append_tables
      WHERE physical_name IN (%s)", in_list
  ))

  if (nrow(versioned) + nrow(appended) == 0L) {
    stop(
      "stow(shape = 'view'): no modelrunnR-managed inputs found in expression. ",
      "Lazy expressions for view-stow must derive from grab().",
      call. = FALSE
    )
  }

  inputs <- vector("list", nrow(versioned) + nrow(appended))
  i <- 1L
  for (j in seq_len(nrow(versioned))) {
    inputs[[i]] <- list(
      name = versioned$logical_name[j],
      hash = versioned$content_hash[j]
    )
    i <- i + 1L
  }
  for (j in seq_len(nrow(appended))) {
    inputs[[i]] <- list(
      name = appended$logical_name[j],
      hash = NA_character_
    )
    i <- i + 1L
  }
  inputs
}

# Orchestrator for shape = "view" stows. Renders the lazy expression
# to SQL, sniffs managed inputs, registers the view via the existing
# `.mr_register_view()` helper, and writes a synthetic _mr_runs row so
# `mr_variant(label)` resolves to this view in a downstream sweep.
.mr_stow_view <- function(name, value, label = NA_character_) {
  con <- .mr_get_connection()

  rendered <- as.character(dbplyr::sql_render(value, con = con))
  if (length(rendered) != 1L || !nzchar(rendered)) {
    stop("stow(shape = 'view'): could not render the lazy expression to SQL.",
         call. = FALSE)
  }

  # Unwrap double-quoted identifiers (e.g. "panel__abc123" -> panel__abc123)
  # so the sniffer's tokenizer matches them as single tokens. Targets only
  # quoted-identifier pairs, leaving any string literals unaffected -- DuckDB
  # uses single quotes for literals, but this guards against future drift.
  rendered_for_sniff <- gsub('"([^"]*)"', '\\1', rendered, perl = TRUE)
  inputs <- .mr_sniff_view_inputs(con, rendered_for_sniff)

  # Namespace guard before any DDL.
  .mr_guard_namespace(name, shape = "A", new_kind = "view", context = "stow")

  # Register the view. Returns the SQL-text content_hash and writes the
  # `_mr_versions` row + CREATE OR REPLACE VIEW.
  hash <- .mr_register_view(name, rendered)

  # Write the synthetic run row so mr_variant() can resolve to this view.
  if (!.mr_is_recording() && !isTRUE(.mr_state$suppress_interactive)) {
    .mr_write_view_interactive_run_row(con, name, hash, inputs, label)
  }

  invisible(hash)
}

# Synthetic _mr_runs row for a free-stow view registration. Distinct
# from `.mr_maybe_record_interactive_write` because it records the
# sniffed inputs on the row, not just the output pair.
.mr_write_view_interactive_run_row <- function(con, name, hash, inputs, label) {
  now <- Sys.time()
  step <- sprintf("<interactive:%s>", format(now, "%Y-%m-%d %H:%M:%OS3"))
  si <- .mr_capture_session_info()

  inputs_json  <- .mr_pairs_to_json(inputs)
  outputs_json <- .mr_pairs_to_json(list(.mr_pair(name, hash)))

  row <- data.frame(
    step              = step,
    run_id            = .mr_new_run_id(),
    inputs            = inputs_json,
    outputs           = outputs_json,
    started_at        = now,
    duration_ms       = 0L,
    status            = "interactive",
    variant_label     = label,
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
  invisible(NULL)
}
