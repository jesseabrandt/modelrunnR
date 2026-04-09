## `pin` and `data` resolution for launch().
##
## `data`  - named list of R values. Each value is stowed (gets a
##           fresh content hash via the normal stow pathway) and the
##           resulting hash is added to the pin map, so the script's
##           `grab(name)` returns exactly what was passed in.
## `pin`   - named list of content hashes OR run ids. Each entry is
##           resolved to a concrete `_mr_versions` row up-front so
##           bad inputs error before the script is sourced.
##
## `data` is applied first; `pin` wins on name collisions.

.mr_start_pinning <- function(pins) {
  .mr_state$pins <- pins
  invisible(NULL)
}

.mr_stop_pinning <- function() {
  .mr_state$pins <- NULL
  invisible(NULL)
}

.mr_pinned_hash <- function(name) {
  pins <- .mr_state$pins
  if (is.null(pins)) return(NULL)
  if (!(name %in% names(pins))) return(NULL)
  pins[[name]]
}

.mr_resolve_pins <- function(pin, data) {
  resolved <- list()

  # 1. data: stow each value, capture the content hash.
  #    These stows are part of launch setup, not REPL activity, so
  #    interactive tracking is suppressed for their duration.
  if (!is.null(data)) {
    if (!is.list(data) || is.null(names(data)) || any(!nzchar(names(data)))) {
      stop("launch(): `data` must be a named list.", call. = FALSE)
    }
    for (nm in names(data)) .mr_validate_name(nm, context = "launch(data=)")
    .mr_state$suppress_interactive <- TRUE
    on.exit(.mr_state$suppress_interactive <- NULL, add = TRUE)
    for (nm in names(data)) {
      value <- data[[nm]]
      if (is.data.frame(value)) {
        .mr_guard_namespace(nm, "table")
        hash <- .mr_stow_table(nm, value)
      } else {
        .mr_guard_namespace(nm, "artifact")
        hash <- .mr_stow_artifact(nm, value)
      }
      resolved[[nm]] <- hash
    }
    .mr_state$suppress_interactive <- NULL
  }

  # 2. pin: resolve by (name, content_hash) first; fall back to run id.
  if (!is.null(pin)) {
    if (!is.list(pin) || is.null(names(pin)) || any(!nzchar(names(pin)))) {
      stop("launch(): `pin` must be a named list.", call. = FALSE)
    }
    for (nm in names(pin)) .mr_validate_name(nm, context = "launch(pin=)")
    con <- .mr_get_connection()
    for (nm in names(pin)) {
      spec <- pin[[nm]]
      if (!is.character(spec) || length(spec) != 1L) {
        stop(sprintf("launch(): pin value for '%s' must be a single string.", nm),
             call. = FALSE)
      }

      hash <- .mr_resolve_pin_spec(con, nm, spec)
      if (is.null(hash)) {
        stop(sprintf(
          "launch(): could not resolve pin '%s' = '%s' (not a known hash or run id for this name).",
          nm, spec
        ), call. = FALSE)
      }
      resolved[[nm]] <- hash
    }
  }

  resolved
}

.mr_resolve_pin_spec <- function(con, name, spec) {
  # Try as a content hash for this name.
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND content_hash = ?",
    params = list(name, spec)
  )
  if (nrow(row) > 0L) return(spec)

  # Fall back to run id lookup: find the hash this run produced for `name`.
  run <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE run_id = ?",
    params = list(spec)
  )
  if (nrow(run) > 0L && !is.na(run$outputs[1])) {
    pairs <- tryCatch(
      jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) {
      if (identical(p$name, name)) return(p$hash)
    }
  }
  NULL
}
