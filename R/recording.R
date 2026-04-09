## Per-launch recording context.
##
## While a recording context is active, every resolved read and write
## is captured as a `list(name, hash)` pair. The run row later
## serializes these lists to JSON in `_mr_runs.inputs` and
## `_mr_runs.outputs`.
##
## Slice 1 recorded names only; Slice 3 evolved the shape to
## name/hash pairs once versioning landed. Deduplication is on
## (name, hash) — if a script reads the exact same version twice,
## it is recorded once.

.mr_start_recording <- function() {
  .mr_state$recording <- list(
    inputs  = list(),
    outputs = list()
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

.mr_pair <- function(name, hash) {
  list(name = name, hash = hash %||% NA_character_)
}

.mr_record_read <- function(name, hash = NA_character_) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  pair <- .mr_pair(name, hash)
  if (!.mr_pair_in(pair, rec$inputs)) {
    rec$inputs <- c(rec$inputs, list(pair))
    .mr_state$recording <- rec
  }
  invisible(NULL)
}

.mr_record_write <- function(name, hash = NA_character_) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  pair <- .mr_pair(name, hash)
  if (!.mr_pair_in(pair, rec$outputs)) {
    rec$outputs <- c(rec$outputs, list(pair))
    .mr_state$recording <- rec
  }
  invisible(NULL)
}

.mr_pair_in <- function(pair, pairs) {
  for (p in pairs) {
    if (identical(p$name, pair$name) && identical(p$hash, pair$hash)) return(TRUE)
  }
  FALSE
}

# Local utility: safe default-or-value operator.
`%||%` <- function(x, y) if (is.null(x)) y else x
