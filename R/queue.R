#' Stage a tracked run without executing it
#'
#' `queue()` registers a run row to `_mr_runs` with `status = "queued"`
#' but does not run the code. The queued row carries everything needed
#' to execute later: `step`, `code_body`, `code_hash`, `rebinds`,
#' `variant_label`, and `batch_id`. Pickup is the existing [launch()]
#' verb called with [mr_run()]:
#'
#' ```r
#' q <- queue({ fit_model(grab("x")) |> stow("model") })
#' launch(mr_run(q$run_id))   # picks up and executes; row updates in place
#' ```
#'
#' Parallel execution is not built in. Compose with `future`/`furrr`,
#' base R loops, or shell-level job runners (e.g. `tsp`, an HPC submit
#' script). modelrunnR records; the consumer executes.
#'
#' @section What's frozen vs refreshed at pickup:
#' When `launch(mr_run(id))` picks up a queued row, the row is updated
#' **in place** (no new `run_id` written). Some columns stay frozen
#' across the update; others are populated for the first time or
#' refreshed.
#'
#' **Frozen** (preserved exactly as queued): `run_id`, `step`,
#' `rebinds`, `batch_id`, `duckdb_seed`.
#'
#' **Refreshed by execution** (NA at queue time, populated at pickup):
#' `started_at`, `duration_ms`, `inputs`, `outputs`, `helpers`,
#' `external_inputs`, plus session/host columns (`hostname`, `os`,
#' `arch`, `r_version`, `n_cpu`, `total_ram_bytes`, `free_ram_bytes`,
#' `attached_packages`, `git_sha`, `git_branch`, `git_dirty`).
#'
#' **Caller-overridable at pickup**: `variant_label` (the queued
#' value carries forward unless `launch(label = ...)` is passed).
#'
#' **`code_body` and `code_hash`**: frozen for **inline steps** (the
#' captured body never changes). For **file steps**, the file is
#' re-sourced from disk at pickup; if the bytes have drifted since
#' queue time, a `warning()` fires naming the queued and current
#' hashes, and the columns refresh to what actually executed. If the
#' file has been deleted, the queue-time snapshot is used and an
#' informational message is emitted.
#'
#' @param code A braced `{ ... }` block (inline), a path to an `.R`
#'   script (file step), [mr_label()] (stages the labeled pipeline's
#'   body), or [mr_run()] (stages a specific run's body). `.sql` paths,
#'   [mr_sql()], and [mr_hash()] are rejected — SQL queueing is out of
#'   scope (v1) and `mr_hash()` addresses content, not pipelines.
#'
#'   `mr_label()` resolution mirrors `launch(mr_label(...))`: re-reads
#'   the file from disk for file steps; uses the stored snapshot for
#'   inline steps. The label is auto-inherited onto the queued row
#'   unless `label = ...` is passed.
#'
#'   `mr_run()` resolution mirrors `launch(mr_run(id))` for
#'   non-queued sources: a new queued row is written from that run's
#'   body. The source row's `variant_label` is auto-inherited unless
#'   `label = ...` is passed. Against a queued source: with `rebind =
#'   ...` the queued row is treated as a template (parallels
#'   `launch(mr_run(qid), rebind = ...)`); without `rebind`, errors
#'   as circular.
#' @param rebind Optional named list, or [mr_binds()] / [mr_envelopes()]
#'   for batch staging (writes N queued rows under one `batch_id`).
#'   Same semantics as `launch(rebind = ...)`.
#' @param external_inputs Optional named list with fields `files` (a
#'   character vector of paths) and/or `env` (a character vector of
#'   environment variable names), same shape as `launch(external_inputs
#'   = ...)`. Each declared input is hashed at queue time and recorded
#'   on the queued row; pickup re-resolves the same declarations
#'   against current state. Missing declared files error at queue
#'   time, before any row is written.
#' @param label Optional `variant_label` for the queued run.
#' @param duckdb_seed Optional numeric seed in `[-1, 1]`, recorded on
#'   the queued row and applied at pickup time.
#' @param ... Reserved for future arguments.
#'
#' @return The queued run record (one row of `_mr_runs`, or N rows for
#'   a batch) with `status = "queued"`, invisibly.
#' @export
queue <- function(code, rebind = NULL, label = NULL,
                  external_inputs = NULL, duckdb_seed = NULL, ...) {
  dots <- list(...)
  if (length(dots) > 0L) {
    stop(sprintf("queue(): unknown arguments: %s",
                 paste(names(dots), collapse = ", ")),
         call. = FALSE)
  }
  script_expr <- substitute(code)

  dispatch <- .mr_dispatch_code_arg(
    code         = code,
    script_expr  = script_expr,
    accept_refs  = c("label", "run"),
    accept_sql   = FALSE,
    caller       = "queue"
  )
  step          <- dispatch$step
  code_body     <- dispatch$code_body
  relaunch_mode <- dispatch$kind %in% c("ref_label", "ref_run")
  relaunch_kind <- if (relaunch_mode) sub("^ref_", "", dispatch$kind) else NULL
  resolved      <- dispatch$ref

  # code_hash for ref kinds: match what launch() would have written.
  # See spec §"Resolution" for the inline-vs-file rule.
  code_hash <- if (relaunch_mode) {
    if (startsWith(step, "<inline:")) {
      .mr_code_hash_inline(code_body, list())
    } else if (file.exists(step)) {
      .mr_code_hash(step, list())
    } else {
      # Resolver fell back to the snapshot; hash over the snapshot.
      .mr_code_hash_inline(code_body, list())
    }
  } else {
    dispatch$code_hash
  }

  # Queued-source circular check (mr_run only). Rejects re-queueing a
  # queued row with no changes; rebind = ... opens the template path.
  if (relaunch_mode && identical(relaunch_kind, "run") &&
      identical(resolved$status, "queued") &&
      is.null(rebind)) {
    stop(sprintf(
      "queue(mr_run('%s')): the source row is itself queued and no rebind was supplied. Re-queueing a queued run with no changes is circular. Either supply rebind = ... to stage a variant, or drain the queued row first via launch(mr_run('%s')).",
      code$value, code$value
    ), call. = FALSE)
  }

  # Non-success source policy (mr_run only). Mirrors launch().
  if (relaunch_mode && identical(relaunch_kind, "run") &&
      !is.na(resolved$status) &&
      !identical(resolved$status, "success") &&
      !identical(resolved$status, "queued")) {
    policy <- match.arg(
      getOption("modelrunnR.relaunch_nonsuccess", "warn"),
      c("warn", "error", "silent")
    )
    msg <- sprintf(
      "queue(): staging from run_id '%s' whose source row has status '%s'.",
      code$value, resolved$status
    )
    if (identical(policy, "error")) {
      stop(paste(msg, "Set options(modelrunnR.relaunch_nonsuccess = \"warn\") to stage anyway."),
           call. = FALSE)
    }
    if (identical(policy, "warn")) warning(msg, call. = FALSE)
  }

  # Label inheritance for refs. Caller's `label` wins; otherwise inherit
  # from the label ref's value (mr_label) or source row's variant_label
  # (mr_run). This must happen BEFORE the existing .mr_validate_label()
  # call so the inherited value is also validated.
  if (relaunch_mode && is.null(label)) {
    label <- if (identical(relaunch_kind, "label")) {
      code$value
    } else {
      # mr_run: source row's variant_label may be NA (unlabeled run)
      vl <- resolved$variant_label
      if (is.na(vl)) NULL else vl
    }
  }

  label <- .mr_validate_label(label)

  if (!is.null(duckdb_seed)) {
    if (!is.numeric(duckdb_seed) || length(duckdb_seed) != 1L || is.na(duckdb_seed)) {
      stop("queue(): duckdb_seed must be a single numeric value.", call. = FALSE)
    }
    if (duckdb_seed < -1 || duckdb_seed > 1) {
      stop(sprintf("queue(): duckdb_seed must be in [-1, 1]; got %s.", duckdb_seed),
           call. = FALSE)
    }
  }

  .mr_get_connection()

  # Resolve external_inputs at queue time. Missing files error here,
  # before _mr_runs is touched, matching launch()'s "missing-files
  # error before the script runs" contract.
  resolved_ext <- .mr_resolve_external_inputs(external_inputs)

  # .mr_resolve_rebinds() writes .mr_state$pending_shape_b_filters as a
  # side effect so launch()'s caller can pick it up; queue() doesn't
  # execute, so it must clear that state itself or the next launch()
  # will inherit a stale Shape B filter.
  on.exit(.mr_state$pending_shape_b_filters <- NULL, add = TRUE)

  # Batch path: dispatch before resolving rebinds. Each envelope is
  # resolved individually inside .mr_queue_batch(), mirroring the
  # launch() batch dispatcher which also skips the top-level resolve
  # when rebind is an mr_binds object.
  if (inherits(rebind, "mr_binds")) {
    return(invisible(.mr_queue_batch(
      step            = step,
      code_body       = code_body,
      code_hash       = code_hash,
      envelopes       = unclass(rebind),
      label           = label,
      external_inputs = resolved_ext,
      duckdb_seed     = duckdb_seed
    )))
  }

  # Resolve rebinds at queue time so the JSON provenance reflects what
  # the user passed (matches launch()'s recording behavior).
  resolved_rebinds <- .mr_resolve_rebinds(rebind)

  run_id <- .mr_new_run_id()
  row <- .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = list(),
    outputs         = list(),
    started_at      = NA,
    duration_ms     = NA_integer_,
    status          = "queued",
    code_hash       = code_hash,
    external_inputs = resolved_ext,
    helpers         = list(),
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = resolved_rebinds$provenance,
    batch_id        = NA_character_,
    session_info    = .mr_blank_session_info()
  )
  invisible(row)
}

# Blank session-context list (all NA), used by queue() so the
# session-context columns reflect "unknown — pickup will populate."
# Field set must match what .mr_capture_session_info() returns; see
# R/session_info.R. After the eddb3a8 git-info commit this includes
# git_sha / git_branch / git_dirty.
.mr_blank_session_info <- function() {
  list(
    hostname          = NA_character_,
    os                = NA_character_,
    arch              = NA_character_,
    r_version         = NA_character_,
    n_cpu             = NA_integer_,
    total_ram_bytes   = NA_real_,
    free_ram_bytes    = NA_real_,
    # `"[]"` not NA: terminal rows store an empty JSON array as the
    # "no packages" sentinel (see .mr_capture_session_info()), so a
    # downstream `jsonlite::fromJSON()` against runs() can parse this
    # column uniformly across queued and finalized rows.
    attached_packages = "[]",
    git_sha           = NA_character_,
    git_branch        = NA_character_,
    git_dirty         = NA_character_
  )
}

# Batch helper for queue(). Writes N queued rows (one per envelope) to
# _mr_runs, all sharing one batch_id. Two phases so that any per-
# envelope failure leaves _mr_runs untouched:
#
#   Phase 1: validate labels and resolve all rebinds. Literal stows
#     happen here and use their own inner transactions, so this phase
#     can't run inside a dbWithTransaction (DuckDB doesn't support
#     nested transactions). If envelope K errors here, no _mr_runs
#     rows have been written yet — earlier envelopes' literal-rebind
#     artifacts may sit in _mr_versions, but the queued rows that
#     would have referenced them never appear.
#   Phase 2: write every row inside one dbWithTransaction so a row-
#     write failure rolls back the whole batch.
.mr_queue_batch <- function(step, code_body, code_hash, envelopes,
                            label, external_inputs, duckdb_seed) {
  n <- length(envelopes)
  if (n == 0L) {
    stop("queue(): mr_binds() expanded to zero envelopes.", call. = FALSE)
  }
  batch_id <- .mr_new_batch_id()

  # Phase 1: resolve every envelope before touching _mr_runs.
  prepared <- vector("list", n)
  for (i in seq_along(envelopes)) {
    env <- envelopes[[i]]
    # Envelope's .label takes precedence over the queue-level label
    # (same precedence as .mr_launch_batch()). Validate the envelope
    # label only when the envelope supplies one; the queue-level label
    # was already validated in queue() before dispatch.
    env_label <- if (".label" %in% names(env)) {
      .mr_validate_label(env$.label)
    } else {
      label
    }
    env_rebind <- env[setdiff(names(env), ".label")]
    if (length(env_rebind) == 0L) env_rebind <- list()
    prepared[[i]] <- list(
      label    = env_label,
      resolved = .mr_resolve_rebinds(env_rebind),
      run_id   = .mr_new_run_id()
    )
  }

  # Phase 2: write every row in one transaction.
  con  <- .mr_get_connection()
  rows <- vector("list", n)
  DBI::dbWithTransaction(con, {
    for (i in seq_along(prepared)) {
      p <- prepared[[i]]
      rows[[i]] <- .mr_write_run_row(
        step            = step,
        run_id          = p$run_id,
        inputs          = list(),
        outputs         = list(),
        started_at      = NA,
        duration_ms     = NA_integer_,
        status          = "queued",
        code_hash       = code_hash,
        external_inputs = external_inputs,
        helpers         = list(),
        variant_label   = p$label,
        code_body       = code_body,
        duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
        rebinds         = p$resolved$provenance,
        batch_id        = batch_id,
        session_info    = .mr_blank_session_info()
      )
    }
  })
  do.call(rbind, rows)
}
