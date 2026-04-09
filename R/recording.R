## Per-launch recording context.
##
## While a recording context is active, every call to `grab()` appends
## the name to `inputs` and every call to `stow()` appends the name to
## `outputs`. Outside a recording context, reads and writes still
## succeed — they simply aren't logged into the run record.
##
## Slice 1 records names only. Slice 3 evolves inputs/outputs to
## carry `{name, hash}` pairs once versioning lands.

.mr_start_recording <- function() {
  .mr_state$recording <- list(
    inputs  = character(),
    outputs = character()
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

.mr_record_read <- function(name) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  # Deduplicate: if a script reads the same name twice, record it once.
  if (!(name %in% rec$inputs)) {
    rec$inputs <- c(rec$inputs, name)
    .mr_state$recording <- rec
  }
  invisible(NULL)
}

.mr_record_write <- function(name) {
  if (!.mr_is_recording()) return(invisible(NULL))
  rec <- .mr_state$recording
  if (!(name %in% rec$outputs)) {
    rec$outputs <- c(rec$outputs, name)
    .mr_state$recording <- rec
  }
  invisible(NULL)
}
