## Batch launches.
##
## When `launch(rebind = mr_binds(...))` fires, control routes here.
## We loop over the expanded envelope list and call `.mr_launch_one()`
## once per envelope using the already-resolved step / code_body /
## relaunch_expr / inline_mode (resolved once at the top of launch()).
## Each envelope contributes its own rebind list and optional `.label`.
##
## Per-envelope errors are captured on that envelope's `_mr_runs` row
## (status = "error") via the `batch_active` flag, which suppresses
## the per-launch re-raise. After all envelopes complete, the batch
## raises or warns based on `on_error =`.

.mr_launch_batch <- function(step, code_body, inline_mode,
                             relaunch_mode, relaunch_expr, script_expr,
                             envelopes, label, external_inputs, force,
                             duckdb_seed, on_error) {
  n <- length(envelopes)
  # Defensive: mr_binds()/mr_envelopes() refuse to construct an
  # empty object today, so this is unreachable from the public API.
  # Kept so a future change that softens the constructors can't reach
  # the loop with nothing to do.
  if (n == 0L) {
    stop("launch(): mr_binds() expanded to zero envelopes.", call. = FALSE)
  }

  # Mirror the SQL-batch nested-launch guard: catch the misuse before
  # ANY envelope runs, not after the first row has been written.
  if (.mr_is_recording() || !is.null(.mr_state$helpers) ||
      !is.null(.mr_state$rebinds)) {
    stop("launch(): nested launches are not supported in v0.1.", call. = FALSE)
  }

  prior_flag <- .mr_state$batch_active
  .mr_state$batch_active <- TRUE
  on.exit(.mr_state$batch_active <- prior_flag, add = TRUE)

  message(sprintf("modelrunnR: batch of %d runs", n))

  rows   <- vector("list", n)
  errors <- vector("list", n)

  for (k in seq_len(n)) {
    env <- envelopes[[k]]
    env_label <- if (".label" %in% names(env)) env$.label else label
    env_rebind <- env[setdiff(names(env), ".label")]
    if (length(env_rebind) == 0L) env_rebind <- list()

    rows[[k]] <- tryCatch(
      .mr_launch_one(
        step            = step,
        code_body       = code_body,
        inline_mode     = inline_mode,
        relaunch_mode   = relaunch_mode,
        relaunch_expr   = relaunch_expr,
        script_expr     = script_expr,
        rebind          = env_rebind,
        label           = env_label,
        external_inputs = external_inputs,
        force           = force,
        duckdb_seed     = duckdb_seed
      ),
      error = function(e) {
        errors[[k]] <<- e
        NULL
      }
    )
  }

  .mr_finalize_batch(n, rows, errors, on_error)
}

# SQL batch: same dispatch model as R-mode batch, but the per-envelope
# launcher is .mr_launch_sql(). src_kind + body_or_path don't depend on
# rebind, so they're shared across envelopes; everything else is per
# envelope.
.mr_launch_batch_sql <- function(src_kind, body_or_path, envelopes,
                                 materialize, label, external_inputs,
                                 force, duckdb_seed, on_error) {
  n <- length(envelopes)
  if (n == 0L) {
    stop("launch(): mr_binds() expanded to zero envelopes.", call. = FALSE)
  }

  if (.mr_is_recording() || !is.null(.mr_state$helpers) ||
      !is.null(.mr_state$rebinds)) {
    stop("launch(): nested launches are not supported in v0.1.", call. = FALSE)
  }

  prior_flag <- .mr_state$batch_active
  .mr_state$batch_active <- TRUE
  on.exit(.mr_state$batch_active <- prior_flag, add = TRUE)

  external_inputs_resolved <- .mr_resolve_external_inputs(external_inputs)
  skip_on_fresh <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))

  message(sprintf("modelrunnR: batch of %d SQL runs", n))

  rows   <- vector("list", n)
  errors <- vector("list", n)

  for (k in seq_len(n)) {
    env <- envelopes[[k]]
    env_label  <- if (".label" %in% names(env)) env$.label else label
    env_rebind <- env[setdiff(names(env), ".label")]
    if (length(env_rebind) == 0L) env_rebind <- list()

    rows[[k]] <- tryCatch({
      # Resolve rebinds inside the per-envelope tryCatch so a dangling
      # mr_hash / mr_variant in one envelope doesn't halt the batch.
      resolved_rebinds <- .mr_resolve_rebinds(env_rebind)
      .mr_launch_sql(
        src_kind                 = src_kind,
        path_or_body             = body_or_path,
        materialize              = materialize,
        rebind                   = resolved_rebinds$map,
        provenance               = resolved_rebinds$provenance,
        external_inputs_resolved = external_inputs_resolved,
        label                    = env_label,
        force                    = force,
        duckdb_seed              = duckdb_seed,
        skip_on_fresh            = skip_on_fresh
      )
    },
    error = function(e) {
      errors[[k]] <<- e
      NULL
    }
    )
  }

  .mr_finalize_batch(n, rows, errors, on_error)
}

# Shared post-loop bookkeeping for both batch dispatchers: collapse the
# per-envelope rows into a single data frame, count errors via both
# the caught-exception path and the status="error" rows, emit the
# summary message, and raise/warn per `on_error`.
#
# User errors inside the block are gated through the batch_active flag
# (see .mr_launch_one) and surface as status="error" rows. Caught
# exceptions cover only the pre-row-write path (e.g. rebind resolution
# failures). The two arms are mutually exclusive per envelope, so a
# simple sum is correct.
.mr_finalize_batch <- function(n, rows, errors, on_error) {
  rows_clean <- rows[!vapply(rows, is.null, logical(1))]
  result_df <- if (length(rows_clean) == 0L) data.frame()
               else do.call(rbind, rows_clean)

  n_errors_caught <- sum(vapply(errors, function(e) !is.null(e), logical(1)))
  n_errors_status <- if (nrow(result_df) > 0L && "status" %in% names(result_df)) {
    sum(result_df$status == "error", na.rm = TRUE)
  } else 0L
  n_errors <- n_errors_caught + n_errors_status

  message(sprintf("modelrunnR: %d/%d succeeded", n - n_errors, n))

  if (n_errors > 0L) {
    msg <- sprintf(
      "launch(): batch had %d/%d errored runs. See `_mr_runs` for details.",
      n_errors, n
    )
    if (identical(on_error, "warn")) {
      warning(msg, call. = FALSE)
    } else {
      stop(msg, call. = FALSE)
    }
  }

  invisible(result_df)
}
