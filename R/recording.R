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

#' Begin a per-launch recording context
#'
#' @param run_id run id stamped onto Shape B rows during the launch
#' @param variant_label variant label stamped onto Shape B rows
#' @return invisibly NULL; initializes `.mr_state$recording`
#' @noRd
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

#' End the recording context and return its captured contents
#'
#' @return the cleared recording list (inputs, outputs, counts, ids)
#' @noRd
.mr_stop_recording <- function() {
  rec <- .mr_state$recording
  .mr_state$recording <- NULL
  rec
}

#' Report whether a recording context is currently active
#'
#' @return TRUE when a recording context exists, else FALSE
#' @noRd
.mr_is_recording <- function() {
  !is.null(.mr_state$recording)
}

# Read-only accessors for the current run_id / variant_label. Return
# NULL when there is no active recording context; otherwise the stored
# value (which may itself be NA when the caller didn't supply one).
#' Read the active recording's run id
#'
#' @return the stored run_id (possibly NA), or NULL if not recording
#' @noRd
.mr_recording_run_id <- function() {
  rec <- .mr_state$recording
  if (is.null(rec)) NULL else rec$run_id
}

#' Read the active recording's variant label
#'
#' @return the stored variant_label (possibly NA), or NULL if not recording
#' @noRd
.mr_recording_variant_label <- function() {
  rec <- .mr_state$recording
  if (is.null(rec)) NULL else rec$variant_label
}

#' Build a `{name, hash}` I/O pair, defaulting a NULL hash to NA
#'
#' @param name logical name
#' @param hash content hash, or NULL/NA
#' @return a list with `name` and `hash` elements
#' @noRd
.mr_pair <- function(name, hash) {
  list(name = name, hash = hash %||% NA_character_)
}

#' Record a read on the active recording's deduplicated inputs
#'
#' @param name logical name read
#' @param hash content hash read
#' @return invisibly NULL; updates the recording context
#' @noRd
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

#' Record a write on the active recording's deduplicated outputs
#'
#' @param name logical name written
#' @param hash content hash written
#' @return invisibly NULL; updates the recording context
#' @noRd
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

#' Test whether an I/O pair is already present in a list of pairs
#'
#' @param pair the `{name, hash}` pair to look for
#' @param pairs list of pairs to search
#' @return TRUE if a pair with matching name and hash exists, else FALSE
#' @noRd
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
#' Record a structured (non-`{name,hash}`) output without deduplication
#'
#' @param entry the structured output entry (e.g. a Shape B append entry)
#' @return invisibly NULL; updates the recording context
#' @noRd
.mr_record_structured_output <- function(entry) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  rec$n_stows <- rec$n_stows + 1L
  rec$outputs <- c(rec$outputs, list(entry))
  .mr_state$recording <- rec
  invisible(NULL)
}

#' Null-coalescing operator: return `y` when `x` is NULL
#'
#' @param x value to return when not NULL
#' @param y fallback value returned when `x` is NULL
#' @return `x` unless it is NULL, in which case `y`
#' @noRd
`%||%` <- function(x, y) if (is.null(x)) y else x
