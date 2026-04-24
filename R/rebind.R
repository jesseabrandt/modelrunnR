## `rebind` resolution for launch().
##
## `rebind` is a named list whose values are either:
##   - a bare R value (data frame or arbitrary R object), stowed into
##     DuckDB through the normal stow pathway so its content_hash
##     becomes the bound value, or
##   - a tagged reference from mr_hash()/mr_run()/mr_variant()/mr_as_of(),
##     resolved to an existing content_hash without round-tripping
##     through R memory.
##
## The resolved map (name -> content_hash) lives in .mr_state$rebinds
## for the duration of the launch and overrides default grab()
## resolution.

.mr_start_rebinding <- function(rebinds, shape_b_filters = NULL) {
  .mr_state$rebinds         <- rebinds
  .mr_state$shape_b_filters <- shape_b_filters
  invisible(NULL)
}

.mr_stop_rebinding <- function() {
  .mr_state$rebinds         <- NULL
  .mr_state$shape_b_filters <- NULL
  invisible(NULL)
}

.mr_rebound_hash <- function(name) {
  rb <- .mr_state$rebinds
  if (is.null(rb)) return(NULL)
  if (!(name %in% names(rb))) return(NULL)
  rb[[name]]
}

.mr_rebound_shape_b_filter <- function(name) {
  f <- .mr_state$shape_b_filters
  if (is.null(f)) return(NULL)
  f[[name]]
}

.mr_resolve_rebinds <- function(rebind) {
  if (is.null(rebind)) return(list(map = list(), provenance = list()))
  if (!is.list(rebind) || is.null(names(rebind)) || any(!nzchar(names(rebind)))) {
    stop("launch(): `rebind` must be a named list.", call. = FALSE)
  }
  for (nm in names(rebind)) .mr_validate_name(nm, context = "launch(rebind=)")

  con <- .mr_get_connection()
  map        <- list()
  provenance <- list()

  # Suppress interactive tracking for inline stows so launch-setup
  # stows don't pollute the interactive-writer warning path.
  .mr_state$suppress_interactive <- TRUE
  on.exit(.mr_state$suppress_interactive <- NULL, add = TRUE)

  shape_b_filters <- list()
  for (nm in names(rebind)) {
    value <- rebind[[nm]]
    entry <- .mr_resolve_rebind_entry(con, nm, value)
    map[[nm]] <- entry$hash
    if (!is.null(entry$shape_b_filter)) {
      shape_b_filters[[nm]] <- entry$shape_b_filter
    }
    provenance[[length(provenance) + 1L]] <- entry$provenance
  }
  .mr_state$pending_shape_b_filters <- if (length(shape_b_filters) > 0L) shape_b_filters else NULL
  list(map = map, provenance = provenance)
}

.mr_resolve_rebind_entry <- function(con, name, value) {
  if (.mr_is_ref(value)) {
    shape <- .mr_lookup_shape(name)
    if (identical(shape, "B")) {
      return(.mr_resolve_rebind_shape_b(con, name, value))
    }
    # Shape A branch (unchanged)
    hash <- switch(value$kind,
      hash    = .mr_resolve_ref_hash(con, name, value$value),
      run     = .mr_resolve_ref_run(con, name, value$value),
      as_of   = .mr_resolve_ref_as_of(con, name, value$value),
      variant = {
        h <- .mr_latest_hash_for_variant(con, name, value$value)
        if (is.null(h)) {
          stop(sprintf(
            "launch(rebind=): mr_variant('%s') has not produced '%s'.",
            value$value, name
          ), call. = FALSE)
        }
        h
      },
      stop(sprintf("launch(rebind=): unknown reference kind '%s'.", value$kind),
           call. = FALSE)
    )
    value_str <- if (identical(value$kind, "as_of")) {
      format(value$value, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
    } else {
      as.character(value$value)
    }
    list(
      hash           = hash,
      shape_b_filter = NULL,
      provenance     = list(name = name, source = value$kind,
                            value = value_str, hash = hash)
    )
  } else {
    # Bare R value -> stow through the normal pathway. The literal-source
    # provenance describes what the user passed in (data frame shape or
    # class/size); the hash links back to the just-stowed version so a
    # join against `_mr_versions` always works.
    if (is.data.frame(value)) {
      .mr_guard_namespace(name, shape = "A", new_kind = "table")
      hash <- .mr_stow_table(name, value)
      value_str <- sprintf("data.frame[%dx%d]", nrow(value), ncol(value))
    } else {
      .mr_guard_namespace(name, shape = "A", new_kind = "artifact")
      hash <- .mr_stow_artifact(name, value)
      value_str <- .mr_format_literal_rebind(value)
    }
    list(
      hash           = hash,
      shape_b_filter = NULL,
      provenance     = list(name = name, source = "literal",
                            value = value_str, hash = hash)
    )
  }
}

# Format an arbitrary (non-data-frame) R value for the run-row provenance
# JSON. Scalar atomics -> format(); other objects -> "<class>[<bytes>B]".
.mr_format_literal_rebind <- function(value) {
  if (is.atomic(value) && length(value) == 1L && !is.null(value)) {
    return(format(value))
  }
  cls <- class(value)[1]
  sz  <- tryCatch(as.numeric(utils::object.size(value)),
                  error = function(e) NA_real_)
  if (is.na(sz)) sprintf("<%s>", cls)
  else sprintf("<%s>[%dB]", cls, as.integer(sz))
}

.mr_resolve_ref_hash <- function(con, name, hash) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND content_hash = ?",
    params = list(name, hash)
  )
  if (nrow(row) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_hash('%s') is not a known content_hash for '%s'.",
      hash, name
    ), call. = FALSE)
  }
  hash
}

.mr_resolve_ref_run <- function(con, name, run_id) {
  run <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(run) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_run('%s') is not a known run id.", run_id
    ), call. = FALSE)
  }
  pairs <- if (is.na(run$outputs[1]) || !nzchar(run$outputs[1])) {
    list()
  } else {
    tryCatch(
      jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE),
      error = function(e) list()
    )
  }
  for (p in pairs) {
    if (identical(p$name, name)) return(p$hash)
  }
  stop(sprintf(
    "launch(rebind=): run '%s' did not produce output '%s'.",
    run_id, name
  ), call. = FALSE)
}

.mr_resolve_ref_as_of <- function(con, name, time) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND first_seen <= ?
      ORDER BY first_seen DESC LIMIT 1",
    params = list(name, time)
  )
  if (nrow(row) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_as_of() found no '%s' version at or before %s.",
      name, format(time)
    ), call. = FALSE)
  }
  row$content_hash[1]
}

# Shape B rebind resolution. mr_run(), mr_variant(), and mr_as_of()
# all resolve to a run_id filter that grab() inside the launch will
# honor. mr_hash() resolves against chunk hashes recorded in
# `_mr_runs.outputs` for append_table entries on this logical name —
# the hash identifies a specific run's appended chunk, which then maps
# to that run's run_id for the Shape B filter.
.mr_resolve_rebind_shape_b <- function(con, name, value) {
  kind <- value$kind
  if (identical(kind, "hash")) {
    rid <- .mr_append_run_id_for_chunk_hash(con, name, value$value)
    if (is.na(rid)) {
      stop(sprintf(
        "launch(rebind=): mr_hash('%s') does not match any chunk of '%s'. See versions('%s') for available hashes.",
        value$value, name, name
      ), call. = FALSE)
    }
    provenance <- list(name = name, source = "hash",
                       value = as.character(value$value),
                       hash = as.character(value$value),
                       shape = "B", filter_kind = "run", filter_value = rid)
    return(list(hash = as.character(value$value), provenance = provenance,
                shape_b_filter = list(kind = "run", value = rid)))
  }
  if (identical(kind, "run")) {
    run <- DBI::dbGetQuery(con,
      "SELECT 1 FROM _mr_runs WHERE run_id = ?", params = list(value$value))
    if (nrow(run) == 0L) {
      stop(sprintf("launch(rebind=): mr_run('%s') is not a known run id.",
                   value$value), call. = FALSE)
    }
    provenance <- list(name = name, source = "run",
                       value = as.character(value$value),
                       hash = NA_character_,
                       shape = "B", filter_kind = "run",
                       filter_value = as.character(value$value))
    return(list(hash = NA_character_, provenance = provenance,
                shape_b_filter = list(kind = "run", value = value$value)))
  }
  if (identical(kind, "variant")) {
    latest <- DBI::dbGetQuery(con,
      "SELECT run_id FROM _mr_runs
        WHERE variant_label = ?
        ORDER BY started_at DESC LIMIT 1",
      params = list(value$value))
    if (nrow(latest) == 0L) {
      stop(sprintf(
        "launch(rebind=): mr_variant('%s') has not produced '%s'.",
        value$value, name), call. = FALSE)
    }
    rid <- latest$run_id[1]
    provenance <- list(name = name, source = "variant",
                       value = as.character(value$value),
                       hash = NA_character_,
                       shape = "B", filter_kind = "run", filter_value = rid)
    return(list(hash = NA_character_, provenance = provenance,
                shape_b_filter = list(kind = "run", value = rid)))
  }
  if (identical(kind, "as_of")) {
    row <- DBI::dbGetQuery(con,
      "SELECT run_id FROM _mr_runs
        WHERE started_at <= ?
        ORDER BY started_at DESC LIMIT 1",
      params = list(value$value))
    if (nrow(row) == 0L) {
      stop(sprintf(
        "launch(rebind=): mr_as_of() found no run at or before %s.",
        format(value$value)), call. = FALSE)
    }
    rid <- row$run_id[1]
    provenance <- list(name = name, source = "as_of",
                       value = format(value$value, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
                       hash = NA_character_,
                       shape = "B", filter_kind = "run", filter_value = rid)
    return(list(hash = NA_character_, provenance = provenance,
                shape_b_filter = list(kind = "run", value = rid)))
  }
  stop(sprintf("launch(rebind=): unknown reference kind '%s'.", kind),
       call. = FALSE)
}
