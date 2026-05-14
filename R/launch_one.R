## Internal: R-mode single-envelope launch.
##
## Extracted from launch() so the batch dispatcher can re-enter the
## same code path per envelope without re-parsing script_expr or
## re-resolving step/code_body. Single-launch callers and the batch
## dispatcher both flow through here; everything specific to "user
## was in single mode" (re-raising errors, etc.) is gated by
## `.mr_state$batch_active` set on the dispatcher's stack frame.
##
## Inputs (all already resolved by launch()'s dispatch):
##   step, code_body, inline_mode, relaunch_mode, relaunch_expr,
##   script_expr -- shape of the user's pipeline.
##   rebind, label, external_inputs, force, duckdb_seed -- per-envelope
##   knobs. `rebind` is the user's named-list (un-resolved); resolution
##   to a name->hash map happens inside.

.mr_launch_one <- function(step, code_body, inline_mode,
                           relaunch_mode, relaunch_expr, script_expr,
                           rebind, label, external_inputs, force,
                           duckdb_seed, batch_id = NA_character_) {
  run_id       <- .mr_new_run_id()
  started_at   <- Sys.time()
  start_secs   <- as.numeric(started_at)
  # Capture session context at launch start so free_ram_bytes reflects
  # what was available before the run's allocations.
  session_info <- .mr_capture_session_info()

  .mr_get_connection()

  resolved_ext <- .mr_resolve_external_inputs(external_inputs)

  resolved_rebinds   <- .mr_resolve_rebinds(rebind)
  rebinds_map        <- resolved_rebinds$map
  rebinds_provenance <- resolved_rebinds$provenance
  shape_b_filters    <- .mr_state$pending_shape_b_filters
  .mr_state$pending_shape_b_filters <- NULL

  staleness <- .mr_is_stale(step, variant_label = label,
                            rebind = rebinds_map)
  skip_on_fresh <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))
  will_skip <- !staleness$stale && !isTRUE(force) && skip_on_fresh
  .mr_print_staleness(step, staleness, will_skip = will_skip)

  if (will_skip) {
    return(invisible(.mr_record_skipped_fresh(
      step            = step,
      run_id          = run_id,
      started_at      = started_at,
      external_inputs = resolved_ext,
      code_body       = code_body,
      label           = label,
      rebinds         = rebinds_provenance,
      duckdb_seed     = duckdb_seed,
      batch_id        = batch_id,
      session_info    = session_info
    )))
  }

  # Apply duckdb_seed after the skip-check so a skipped_fresh run does
  # not perturb the connection's RNG state. SQL-mode does it in the
  # same order; keep the two paths consistent.
  if (!is.null(duckdb_seed)) {
    con_for_seed <- .mr_get_connection()
    DBI::dbExecute(con_for_seed, "SELECT setseed(?)", params = list(duckdb_seed))
  }

  .mr_guard_no_nested_launch()

  .mr_start_recording(run_id = run_id, variant_label = label)
  .mr_start_helper_tracking()
  .mr_start_rebinding(rebinds_map, shape_b_filters)
  on.exit(
    {
      if (.mr_is_recording()) .mr_stop_recording()
      if (!is.null(.mr_state$helpers)) .mr_stop_helper_tracking()
      .mr_stop_rebinding()
    },
    add = TRUE
  )

  status  <- "success"
  err_obj <- NULL
  tryCatch(
    if (inline_mode) {
      .mr_eval_inline(script_expr)
    } else if (relaunch_mode && !is.null(relaunch_expr)) {
      .mr_eval_inline(relaunch_expr)
    } else {
      .mr_source_script(step)
    },
    error = function(e) {
      status  <<- "error"
      err_obj <<- e
    }
  )

  rec          <- .mr_stop_recording()
  helper_bytes <- .mr_helper_bytes()
  helpers      <- .mr_stop_helper_tracking()
  duration_ms  <- as.integer(round((as.numeric(Sys.time()) - start_secs) * 1000))

  code_hash <- if (inline_mode || (relaunch_mode && !is.null(relaunch_expr))) {
    .mr_code_hash_inline(code_body, helpers)
  } else {
    .mr_code_hash(step, helpers)
  }

  # L0 source snapshot: persist script + helper bytes keyed by
  # code_hash. Fires inside the launch but before the run row is
  # written, so a snapshot-write failure surfaces as a launch error
  # rather than leaving a run row whose source can't be recovered.
  .mr_record_code_snapshot(
    con          = .mr_get_connection(),
    code_hash    = code_hash,
    script_path  = if (inline_mode) NA_character_ else step,
    script_bytes = .mr_script_bytes_for_snapshot(code_body),
    helpers_with_bytes = .mr_pack_helpers(helpers, helper_bytes),
    inline       = inline_mode || (relaunch_mode && !is.null(relaunch_expr))
  )

  .mr_warn_interactive_inputs(step, rec$inputs)

  propagation_source <- NULL
  if (is.na(label)) {
    con_for_prop <- .mr_get_connection()
    prop <- .mr_propagate_label(con_for_prop, rec$inputs)
    if (!is.na(prop)) {
      inherited_label <- unclass(prop)
      label <- inherited_label
      propagation_source <- .mr_first_input_producing(rec$inputs,
                                                       con_for_prop,
                                                       inherited_label)
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
    inputs          = rec$inputs,
    outputs         = rec$outputs,
    started_at      = started_at,
    duration_ms     = duration_ms,
    status          = status,
    code_hash       = code_hash,
    external_inputs = resolved_ext,
    helpers         = helpers,
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = rebinds_provenance,
    batch_id        = batch_id,
    session_info    = session_info
  )

  .mr_print_timing_summary(
    step,
    duration_ms,
    status,
    n_grabs            = rec$n_grabs,
    n_stows            = rec$n_stows,
    variant_label      = label,
    propagation_source = propagation_source
  )

  if (!is.null(err_obj) && !isTRUE(.mr_state$batch_active)) {
    stop(err_obj)
  }

  invisible(run_row)
}
