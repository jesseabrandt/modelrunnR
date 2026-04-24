## Per-launch recording context.
##
## While a recording context is active, every resolved read and write
## is captured as a `list(name, hash)` pair. The run row later
## serializes these lists to JSON in `_mr_runs.inputs` and
## `_mr_runs.outputs`.
##
## Also carries the current run_id and variant_label so Shape B stow
## can stamp `_mr_run_id` / `_mr_variant_label` system columns on the
## rows it appends.

.mr_start_recording <- function(run_id = NA_character_,
                                variant_label = NA_character_) {
  .mr_state$recording <- list(
    inputs        = list(),
    outputs       = list(),
    n_grabs       = 0L,
    n_stows       = 0L,
    run_id        = run_id,
    variant_label = variant_label
  )
  invisible(NULL)
}

.mr_stop_recording <- function() {
  rec <- .mr_state$recording
  .mr_state$recording <- NULL
  rec
}

.mr_is_recording <- function() {
  !is.null(.mr_state$recording)
}

# Read-only accessors for the current run_id / variant_label. Return
# NULL when there is no active recording context; otherwise the stored
# value (which may itself be NA when the caller didn't supply one).
.mr_recording_run_id <- function() {
  rec <- .mr_state$recording
  if (is.null(rec)) NULL else rec$run_id
}

.mr_recording_variant_label <- function() {
  rec <- .mr_state$recording
  if (is.null(rec)) NULL else rec$variant_label
}

.mr_pair <- function(name, hash) {
  list(name = name, hash = hash %||% NA_character_)
}

.mr_record_read <- function(name, hash = NA_character_) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  pair <- .mr_pair(name, hash)
  rec$n_grabs <- rec$n_grabs + 1L
  if (!.mr_pair_in(pair, rec$inputs)) {
    rec$inputs <- c(rec$inputs, list(pair))
  }
  .mr_state$recording <- rec
  invisible(NULL)
}

.mr_record_write <- function(name, hash = NA_character_) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  pair <- .mr_pair(name, hash)
  rec$n_stows <- rec$n_stows + 1L
  if (!.mr_pair_in(pair, rec$outputs)) {
    rec$outputs <- c(rec$outputs, list(pair))
  }
  .mr_state$recording <- rec
  invisible(NULL)
}

.mr_pair_in <- function(pair, pairs) {
  for (p in pairs) {
    if (identical(p$name, pair$name) && identical(p$hash, pair$hash)) return(TRUE)
  }
  FALSE
}

# Record a structured output (non-{name,hash} shape) on the current
# recording. Used by Shape B writes for their append_table entry.
# Deduplication is intentionally NOT performed — Shape B writes are
# run-indexed and one-per-logical-name-per-run is the expected pattern;
# stray double-stow under one run is unusual enough that preserving
# the entry is more useful than collapsing it.
.mr_record_structured_output <- function(entry) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  rec$n_stows <- rec$n_stows + 1L
  rec$outputs <- c(rec$outputs, list(entry))
  .mr_state$recording <- rec
  invisible(NULL)
}

`%||%` <- function(x, y) if (is.null(x)) y else x
