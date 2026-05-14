## Helper-file tracking during a tracked launch.
##
## Launch installs a shadowing `source` binding inside the script's
## evaluation environment so every `source("helper.R")` call the
## script (or a transitively-sourced helper) makes records the
## helper's normalized path and byte hash. Cycles are broken by
## tracking an in-flight set: if a file is already being sourced,
## the wrapper short-circuits the recursive dispatch rather than
## looping.

# Build a `source`-compatible wrapper that records helper hashes
# into .mr_state$helpers and delegates to base::source() for the
# actual evaluation.
.mr_make_source_wrapper <- function() {
  function(file, local = TRUE, ...) {
    path <- normalizePath(file, mustWork = TRUE)

    # Cycle-breaker: if this file is already being sourced, skip
    # the recursive call to avoid an infinite loop.
    inflight <- .mr_state$source_inflight %||% character()
    if (path %in% inflight) {
      return(invisible(NULL))
    }

    # Record the helper's code hash once per unique path. Bytes are
    # retained in parallel so the L0 source-snapshot recorder can
    # persist them to `_mr_code_helpers` without re-reading the file
    # (which could have changed between source-time and snapshot-time).
    helpers <- .mr_state$helpers %||% list()
    if (is.null(helpers[[path]])) {
      bytes <- .mr_read_code_bytes(path)
      helpers[[path]] <- .mr_hash_bytes(bytes)
      .mr_state$helpers <- helpers
      helper_bytes <- .mr_state$helper_bytes %||% list()
      helper_bytes[[path]] <- bytes
      .mr_state$helper_bytes <- helper_bytes
    }

    # Track in-flight and ensure cleanup even on error.
    .mr_state$source_inflight <- c(inflight, path)
    on.exit({
      .mr_state$source_inflight <- setdiff(.mr_state$source_inflight, path)
    }, add = TRUE)

    # Resolve default `local = TRUE` semantics to the calling frame
    # (the script env) so recursive sourcing stays in the script's
    # evaluation environment rather than leaking into our wrapper's.
    if (identical(local, TRUE)) local <- parent.frame()
    base::source(file, local = local, ...)
  }
}

.mr_start_helper_tracking <- function() {
  .mr_state$helpers         <- list()
  .mr_state$helper_bytes    <- list()
  .mr_state$source_inflight <- character()
  invisible(NULL)
}

# Returns the path -> hash map for the just-finished tracking session
# (backward-compatible shape: hashes only, no bytes). Bytes are
# accessible via `.mr_helper_bytes()` BEFORE this is called -- the
# snapshot recorder pulls them off state and persists them.
.mr_stop_helper_tracking <- function() {
  helpers <- .mr_state$helpers
  .mr_state$helpers         <- NULL
  .mr_state$helper_bytes    <- NULL
  .mr_state$source_inflight <- NULL
  helpers
}

# Bytes-bearing accessor for the in-flight helper tracking state.
# Returns a path -> raw map; empty list when no tracking is active.
# Must be called BEFORE `.mr_stop_helper_tracking()` to capture bytes
# for the L0 snapshot recorder.
.mr_helper_bytes <- function() {
  .mr_state$helper_bytes %||% list()
}

.mr_read_code_bytes <- function(path) {
  # Used only for CODE hashing (scripts and their sourced helpers).
  # Read as text (always UTF-8) and normalize line endings so the
  # same script produces the same hash whether it was saved on
  # Windows (CRLF) or Unix (LF). Data files MUST NOT route through
  # this function -- use .mr_file_hash() (tools::md5sum on raw bytes)
  # when byte-exact equality is required.
  txt <- readLines(path, warn = FALSE, encoding = "UTF-8")
  normalized <- paste(txt, collapse = "\n")
  charToRaw(normalized)
}
