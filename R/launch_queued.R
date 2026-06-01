## In-place pickup of a queued run row.
##
## Called from launch() when launch(mr_run(id)) resolves a row whose
## status is "queued". Executes the row's code_body (or re-sources the
## file for file steps) and UPDATEs the row in place: status flips,
## execution columns populate.
##
## Truly frozen across the UPDATE: run_id, step, rebinds, batch_id,
## duckdb_seed. Re-written by the UPDATE (caller-overridable or
## recomputed): code_body, code_hash, variant_label.
##   - For inline steps, code_body and code_hash get the same value
##     they had at queue time (the body never changes).
##   - For file steps, the resolver re-reads from disk; if the file
##     has drifted, a warning fires (see drift block below) and the
##     refreshed code_body/code_hash reflect what actually executed.
##   - variant_label is overridable by the caller's launch(label=)
##     at pickup time; otherwise it stays equal to the queued row's.
##
## Key design note — rebind round-trip:
##   The queued row's `rebinds` column holds the provenance JSON written
##   by `.mr_resolve_rebinds()` at queue time. Each entry has the shape:
##     {name, source, value, hash}   (Shape A)
##     {name, source, value, hash, shape, filter_kind, filter_value}  (Shape B)
##   All required hashes are already resolved and stored. Pickup
##   reconstructs the rebinds_map (name→hash) and shape_b_filters
##   directly from that JSON via `.mr_map_from_provenance_json()`, which
##   avoids any lossy round-trip through R values.

#' Execute a queued run row in place and finalize its run record
#'
#' @param run_id run id of the queued row to pick up
#' @param resolved resolver result carrying step, code_body, and expr
#' @param label variant label override (NA to keep the queued row's)
#' @param external_inputs pickup-time external inputs (already nulled by caller)
#' @param force logical; if TRUE, run even when the step is fresh
#' @param duckdb_seed seed override (NULL to use the queued row's seed)
#' @return the finalized _mr_runs row, invisibly
#' @noRd
.mr_pickup_queued_run <- function(run_id, resolved, label, external_inputs,
                                  force, duckdb_seed) {
  con <- .mr_get_connection()
  prior <- DBI::dbGetQuery(
    con,
    "SELECT step, code_body, code_hash, variant_label, rebinds, batch_id,
            duckdb_seed, external_inputs
       FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(prior) == 0L) {
    stop(sprintf(".mr_pickup_queued_run(): row vanished for run_id '%s'.", run_id),
         call. = FALSE)
  }

  step          <- resolved$step
  code_body     <- resolved$code_body
  relaunch_expr <- resolved$expr   # NULL for file steps that exist on disk
  inline_mode   <- startsWith(step, "<inline:")

  # File-step drift detection. The resolver's `code_body` came from
  # disk (or the snapshot fallback); compare its hash against the
  # queued row's `code_hash` to detect "the file you queued isn't the
  # file you're about to run." Inline rows can't drift — `code_body`
  # came from the queued row itself. When the file is gone the resolver
  # has already fallen back to the snapshot (relaunch_expr is non-NULL)
  # and `file.exists(step)` gates us out, so no spurious drift fires.
  if (!inline_mode && file.exists(step)) {
    fresh_hash  <- .mr_code_hash(step, list())
    queued_hash <- prior$code_hash[1]
    if (!is.na(queued_hash) && !identical(fresh_hash, queued_hash)) {
      warning(sprintf(
        "launch(mr_run('%s')): the file '%s' has drifted since queue time (queued hash %s, current %s). Re-sourcing from disk.",
        run_id, step,
        substr(queued_hash, 1L, 12L), substr(fresh_hash, 1L, 12L)
      ), call. = FALSE)
    }
  }

  # Seed precedence: caller's explicit seed overrides the queued row's.
  if (is.null(duckdb_seed)) {
    queued_seed <- prior$duckdb_seed[1]
    duckdb_seed <- if (is.na(queued_seed)) NULL else queued_seed
  }

  # Label precedence: caller's explicit label overrides the queued row's.
  if (is.na(label)) label <- prior$variant_label[1]

  # Reconstruct the rebinds map + shape_b_filters directly from the
  # stored provenance JSON. This is non-lossy: all hashes were resolved
  # at queue time and are sitting in the JSON. The local
  # `shape_b_filters` is passed straight to .mr_start_rebinding() below;
  # we never write .mr_state$pending_shape_b_filters here, since pickup
  # has its own start-rebinding call and leaving that state set would
  # leak into the next launch().
  maps <- .mr_map_from_provenance_json(prior$rebinds[1])
  rebinds_map     <- maps$rebinds_map
  shape_b_filters <- maps$shape_b_filters

  started_at   <- Sys.time()
  start_secs   <- as.numeric(started_at)

  # Pre-execution error guard: any error before the row is finalized
  # leaves the queued row stranded as "queued". Track whether we hit a
  # terminal-status update; if not, on.exit stamps the row "error" so
  # the user sees the failure rather than an indefinitely-queued row.
  row_finalized <- FALSE
  session_info  <- .mr_blank_session_info()
  on.exit({
    if (!row_finalized) {
      try(.mr_update_queued_row(
        run_id          = run_id,
        status          = "error",
        started_at      = started_at,
        duration_ms     = as.integer(round(
          (as.numeric(Sys.time()) - start_secs) * 1000)),
        inputs          = list(),
        outputs         = list(),
        external_inputs = list(files = list(), env = list()),
        helpers         = list(),
        session_info    = session_info,
        code_body       = code_body,
        code_hash       = prior$code_hash[1],
        variant_label   = if (is.na(label)) prior$variant_label[1] else label
      ), silent = TRUE)
    }
  }, add = TRUE)

  session_info <- .mr_capture_session_info()

  # external_inputs is staged on the queued row at queue time. The
  # caller's pickup-time external_inputs has already been warned about
  # and nulled by launch.R's queued-pickup branch. Re-resolve the
  # staged declarations against current state so hashes reflect the
  # files / env vars at pickup time (drift detection happens through
  # the next launch's staleness check, not here).
  staged_ext_decl <- .mr_external_inputs_decl_from_json(prior$external_inputs[1])
  resolved_ext    <- .mr_resolve_external_inputs(staged_ext_decl)

  # Freshness check at pickup, not queue time (per spec).
  staleness     <- .mr_is_stale(step, variant_label = label, rebind = rebinds_map)
  skip_on_fresh <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))
  will_skip     <- !staleness$stale && !isTRUE(force) && skip_on_fresh
  .mr_print_staleness(step, staleness, will_skip = will_skip)

  if (will_skip) {
    skip_code_hash <- if (inline_mode) {
      prior$code_hash[1]
    } else {
      .mr_code_hash(step, list())
    }
    # L0 source snapshot: if the file drifted since queue time, the
    # new `skip_code_hash` has no existing `_mr_code` row. Snapshot
    # the current file bytes under the new hash so the row's
    # code_hash remains source-recoverable; the old hash's snapshot
    # (from queue time) stays in place under its own hash.
    if (!inline_mode && file.exists(step)) {
      .mr_record_code_snapshot(
        con          = .mr_get_connection(),
        code_hash    = skip_code_hash,
        script_path  = step,
        script_bytes = .mr_read_code_bytes(step),
        helpers_with_bytes = list(),
        inline       = FALSE
      )
    }
    .mr_update_queued_row(
      run_id          = run_id,
      status          = "skipped_fresh",
      started_at      = started_at,
      duration_ms     = 0L,
      inputs          = list(),
      outputs         = list(),
      external_inputs = resolved_ext,
      helpers         = list(),
      session_info    = session_info,
      code_body       = code_body,
      code_hash       = skip_code_hash,
      variant_label   = label
    )
    row_finalized <- TRUE
    return(invisible(.mr_runs_row(run_id)))
  }

  if (!is.null(duckdb_seed)) {
    DBI::dbExecute(.mr_get_connection(), "SELECT setseed(?)",
                   params = list(duckdb_seed))
  }

  .mr_guard_no_nested_launch()
  .mr_start_recording(run_id = run_id, variant_label = label)
  .mr_start_helper_tracking()
  .mr_start_rebinding(rebinds_map, shape_b_filters)
  on.exit({
    if (.mr_is_recording()) .mr_stop_recording()
    if (!is.null(.mr_state$helpers)) .mr_stop_helper_tracking()
    .mr_stop_rebinding()
  }, add = TRUE)

  status  <- "success"
  err_obj <- NULL
  tryCatch(
    if (inline_mode) {
      .mr_eval_inline(parse(text = code_body))
    } else if (!is.null(relaunch_expr)) {
      .mr_eval_inline(relaunch_expr)
    } else {
      .mr_source_script(step)
    },
    error = function(e) { status <<- "error"; err_obj <<- e }
  )

  rec          <- .mr_stop_recording()
  helper_bytes <- .mr_helper_bytes()
  helpers      <- .mr_stop_helper_tracking()
  duration_ms  <- as.integer(round((as.numeric(Sys.time()) - start_secs) * 1000))

  file_gone <- !inline_mode && !file.exists(step)
  code_hash <- if (inline_mode) {
    .mr_code_hash_inline(code_body, helpers)
  } else if (!file_gone) {
    .mr_code_hash(step, helpers)
  } else {
    # File is gone; we ran the stored snapshot (code_body). Hash over
    # the snapshot text so the row stays self-consistent.
    .mr_code_hash_inline(code_body, helpers)
  }

  # L0 source snapshot: persist script + helper bytes keyed by
  # code_hash. Inline-shape when the source path is gone, so the
  # `inline` column matches how the hash was computed.
  .mr_record_code_snapshot(
    con          = .mr_get_connection(),
    code_hash    = code_hash,
    script_path  = if (inline_mode || file_gone) NA_character_ else step,
    script_bytes = .mr_script_bytes_for_snapshot(code_body),
    helpers_with_bytes = .mr_pack_helpers(helpers, helper_bytes),
    inline       = inline_mode || file_gone
  )

  .mr_print_timing_summary(
    step, duration_ms, status,
    n_grabs       = rec$n_grabs,
    n_stows       = rec$n_stows,
    variant_label = label
  )

  .mr_update_queued_row(
    run_id          = run_id,
    status          = status,
    started_at      = started_at,
    duration_ms     = duration_ms,
    inputs          = rec$inputs,
    outputs         = rec$outputs,
    external_inputs = resolved_ext,
    helpers         = helpers,
    session_info    = session_info,
    code_body       = code_body,
    code_hash       = code_hash,
    variant_label   = label
  )
  row_finalized <- TRUE

  if (!is.null(err_obj)) stop(err_obj)
  invisible(.mr_runs_row(run_id))
}

# UPDATE _mr_runs SET execution columns WHERE run_id = ?
# Frozen columns (step, rebinds, batch_id, run_id) are NOT touched.
# git_sha / git_branch / git_dirty are populated from session_info.
#' UPDATE a queued _mr_runs row's execution columns in place
#'
#' @param run_id run id identifying the row to update
#' @param status terminal run status to write
#' @param started_at run start timestamp
#' @param duration_ms run duration in milliseconds
#' @param inputs resolved input (name, hash) pairs
#' @param outputs resolved output (name, hash) pairs
#' @param external_inputs resolved external-input declarations
#' @param helpers transitively-sourced helper records
#' @param session_info captured session-context snapshot
#' @param code_body source body that executed
#' @param code_hash code hash recorded for the run
#' @param variant_label variant label recorded for the run
#' @return invisibly, the result of the UPDATE
#' @noRd
.mr_update_queued_row <- function(run_id, status, started_at, duration_ms,
                                  inputs, outputs, external_inputs, helpers,
                                  session_info, code_body, code_hash,
                                  variant_label) {
  con <- .mr_get_connection()
  DBI::dbExecute(con,
    "UPDATE _mr_runs SET
        status            = ?,
        started_at        = ?,
        duration_ms       = ?,
        inputs            = ?,
        outputs           = ?,
        external_inputs   = ?,
        helpers           = ?,
        hostname          = ?,
        os                = ?,
        arch              = ?,
        r_version         = ?,
        n_cpu             = ?,
        total_ram_bytes   = ?,
        free_ram_bytes    = ?,
        attached_packages = ?,
        git_sha           = ?,
        git_branch        = ?,
        git_dirty         = ?,
        code_body         = ?,
        code_hash         = ?,
        variant_label     = ?
      WHERE run_id = ?",
    params = list(
      status, started_at, duration_ms,
      .mr_pairs_to_json(inputs), .mr_pairs_to_json(outputs),
      .mr_external_inputs_to_json(external_inputs),
      .mr_helpers_to_json(helpers),
      session_info$hostname,
      session_info$os,
      session_info$arch,
      session_info$r_version,
      session_info$n_cpu,
      session_info$total_ram_bytes,
      session_info$free_ram_bytes,
      session_info$attached_packages,
      session_info$git_sha,
      session_info$git_branch,
      session_info$git_dirty,
      code_body, code_hash, variant_label,
      run_id
    )
  )
}

# Read back a single _mr_runs row for return-value parity with launch().
#' Read back a single _mr_runs row by run id
#'
#' @param run_id run id to fetch
#' @return the matching _mr_runs row as a data.frame
#' @noRd
.mr_runs_row <- function(run_id) {
  con <- .mr_get_connection()
  DBI::dbGetQuery(con, "SELECT * FROM _mr_runs WHERE run_id = ?",
                  params = list(run_id))
}

# Reconstruct rebinds_map (name -> hash) and shape_b_filters from the
# provenance JSON stored on a queued row.
#
# Provenance entry shapes (from .mr_resolve_rebind_entry() in R/rebind.R):
#
#   Shape A (literal, hash, run, as_of, variant):
#     {name, source, value, hash}
#
#   Shape B (hash, run, variant, as_of with shape="B"):
#     {name, source, value, hash, shape, filter_kind, filter_value}
#
# This function reads the stored hashes directly — no re-resolution
# against the DB is needed, and no lossy literal round-trip occurs.
# For Shape B entries the filter is reconstructed from filter_kind /
# filter_value so grab() inside the pickup run applies the correct
# run-id scope.
#' Reconstruct the rebinds map and shape-B filters from provenance JSON
#'
#' @param json_text provenance JSON stored on a queued row
#' @return list with `rebinds_map` (name -> hash) and `shape_b_filters`
#' @noRd
.mr_map_from_provenance_json <- function(json_text) {
  empty <- list(rebinds_map = list(), shape_b_filters = list())
  if (is.na(json_text) || !nzchar(json_text) || identical(json_text, "[]")) {
    return(empty)
  }
  entries <- tryCatch(
    jsonlite::fromJSON(json_text, simplifyVector = FALSE),
    error = function(e) list()
  )
  if (length(entries) == 0L) return(empty)

  rebinds_map     <- list()
  shape_b_filters <- list()

  for (e in entries) {
    nm <- e$name
    if (is.null(nm) || !nzchar(nm)) next

    # Shape B: hash may be NA for run/variant/as_of entries; filter is
    # what grab() actually uses.
    if (identical(e$shape, "B")) {
      fk <- e$filter_kind
      fv <- e$filter_value
      if (!is.null(fk) && !is.null(fv) && nzchar(fv)) {
        shape_b_filters[[nm]] <- list(kind = fk, value = fv)
      }
      # Shape B rebinds_map hash is NA for run/variant/as_of; still set
      # it so .mr_start_rebinding() sees the name.
      rebinds_map[[nm]] <- if (!is.null(e$hash) && !is.na(e$hash)) {
        e$hash
      } else {
        NA_character_
      }
    } else {
      # Shape A: hash is the resolved content_hash.
      rebinds_map[[nm]] <- if (!is.null(e$hash) && !is.na(e$hash)) {
        e$hash
      } else {
        NA_character_
      }
    }
  }

  list(rebinds_map = rebinds_map, shape_b_filters = shape_b_filters)
}
