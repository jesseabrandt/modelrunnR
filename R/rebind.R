## `rebind` resolution for launch().
##
## `rebind` is a named list whose values are either:
##   - a bare R value (data frame or arbitrary R object), stowed into
##     DuckDB through the normal stow pathway so its content_hash
##     becomes the bound value, or
##   - a tagged reference from mr_hash()/mr_run()/mr_variant()/mr_as_of(),
##     resolved to an existing content_hash without round-tripping
##     through R memory.
##
## The resolved map (name -> content_hash) lives in .mr_state$rebinds
## for the duration of the launch and overrides default grab()
## resolution.

.mr_start_rebinding <- function(rebinds) {
  .mr_state$rebinds <- rebinds
  invisible(NULL)
}

.mr_stop_rebinding <- function() {
  .mr_state$rebinds <- NULL
  invisible(NULL)
}

.mr_rebound_hash <- function(name) {
  rb <- .mr_state$rebinds
  if (is.null(rb)) return(NULL)
  if (!(name %in% names(rb))) return(NULL)
  rb[[name]]
}

.mr_resolve_rebinds <- function(rebind) {
  if (is.null(rebind)) return(list())
  if (!is.list(rebind) || is.null(names(rebind)) || any(!nzchar(names(rebind)))) {
    stop("launch(): `rebind` must be a named list.", call. = FALSE)
  }
  for (nm in names(rebind)) .mr_validate_name(nm, context = "launch(rebind=)")

  con <- .mr_get_connection()
  resolved <- list()

  # Suppress interactive tracking for inline stows so launch-setup
  # stows don't pollute the interactive-writer warning path.
  .mr_state$suppress_interactive <- TRUE
  on.exit(.mr_state$suppress_interactive <- NULL, add = TRUE)

  for (nm in names(rebind)) {
    value <- rebind[[nm]]
    resolved[[nm]] <- .mr_resolve_rebind_entry(con, nm, value)
  }
  resolved
}

.mr_resolve_rebind_entry <- function(con, name, value) {
  if (.mr_is_ref(value)) {
    switch(value$kind,
      hash    = .mr_resolve_ref_hash(con, name, value$value),
      run     = .mr_resolve_ref_run(con, name, value$value),
      as_of   = .mr_resolve_ref_as_of(con, name, value$value),
      variant = stop(
        "launch(rebind=): mr_variant() resolution is not yet implemented ",
        "(scheduled for Slice C of the swappability plan).",
        call. = FALSE
      ),
      stop(sprintf("launch(rebind=): unknown reference kind '%s'.", value$kind),
           call. = FALSE)
    )
  } else {
    # Bare R value -> stow through the normal pathway.
    if (is.data.frame(value)) {
      .mr_guard_namespace(name, "table")
      .mr_stow_table(name, value)
    } else {
      .mr_guard_namespace(name, "artifact")
      .mr_stow_artifact(name, value)
    }
  }
}

.mr_resolve_ref_hash <- function(con, name, hash) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND content_hash = ?",
    params = list(name, hash)
  )
  if (nrow(row) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_hash('%s') is not a known content_hash for '%s'.",
      hash, name
    ), call. = FALSE)
  }
  hash
}

.mr_resolve_ref_run <- function(con, name, run_id) {
  run <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(run) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_run('%s') is not a known run id.", run_id
    ), call. = FALSE)
  }
  pairs <- if (is.na(run$outputs[1]) || !nzchar(run$outputs[1])) {
    list()
  } else {
    tryCatch(
      jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE),
      error = function(e) list()
    )
  }
  for (p in pairs) {
    if (identical(p$name, name)) return(p$hash)
  }
  stop(sprintf(
    "launch(rebind=): run '%s' did not produce output '%s'.",
    run_id, name
  ), call. = FALSE)
}

.mr_resolve_ref_as_of <- function(con, name, time) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND first_seen <= ?
      ORDER BY first_seen DESC LIMIT 1",
    params = list(name, time)
  )
  if (nrow(row) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_as_of() found no '%s' version at or before %s.",
      name, format(time)
    ), call. = FALSE)
  }
  row$content_hash[1]
}
