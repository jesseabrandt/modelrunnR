## Interactive I/O tracking.
##
## When `stow()` or `ingest()` is called outside a tracked `launch()`,
## the write is attributed to a synthetic step id of the form
## `<interactive:YYYY-MM-DD HH:MM:OS3>`. One _mr_runs row is written
## per interactive write so later launches can detect when a script's
## inputs trace back to the REPL -- a reproducibility land mine the
## design doc explicitly wants surfaced.
##
## Interactive reads (`grab()` outside launch) are intentionally not
## recorded: reads don't change state, and logging every REPL
## exploration would bloat the metadata without any benefit.

.mr_maybe_record_interactive_write <- function(name, hash) {
  if (.mr_is_recording()) return(invisible(NULL))
  # launch() suppresses interactive tracking while resolving inline `rebind`
  # values -- those stows are launch setup, not REPL activity.
  if (isTRUE(.mr_state$suppress_interactive)) return(invisible(NULL))

  con <- .mr_get_connection()
  now <- Sys.time()
  step <- sprintf("<interactive:%s>", format(now, "%Y-%m-%d %H:%M:%OS3"))

  row <- data.frame(
    step          = step,
    run_id        = .mr_new_run_id(),
    inputs        = "[]",
    outputs       = .mr_pairs_to_json(list(.mr_pair(name, hash))),
    started_at    = now,
    duration_ms   = 0L,
    status        = "interactive",
    variant_label = NA_character_,
    stringsAsFactors = FALSE
  )
  DBI::dbAppendTable(con, "_mr_runs", row)
  invisible(NULL)
}

# Return the `step` of the most recent _mr_runs row that produced
# `(name, hash)`, or NA if no such row exists. Used by launch() to
# detect inputs that trace back to interactive writes.
#
# Two output entry shapes are recognized:
#   - Shape A / ingest: {name, hash}. Matched by `name` AND `hash`.
#   - Shape B append_table: {kind = "append_table", logical_name, ...}.
#     Matched by `logical_name` only — Shape B grabs record `hash = NA`
#     because an append table's identity is run-indexed, not hashable
#     across all rows.
.mr_last_producer_step <- function(con, name, hash) {
  runs <- DBI::dbGetQuery(
    con,
    "SELECT step, outputs FROM _mr_runs
      WHERE outputs IS NOT NULL AND outputs <> '[]'
      ORDER BY started_at DESC"
  )
  if (nrow(runs) == 0L) return(NA_character_)
  for (i in seq_len(nrow(runs))) {
    entries <- tryCatch(
      jsonlite::fromJSON(runs$outputs[i], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (e in entries) {
      if (identical(e$kind, "append_table")) {
        if (identical(e$logical_name, name)) return(runs$step[i])
      } else {
        if (identical(e$name, name) && identical(e$hash, hash)) {
          return(runs$step[i])
        }
      }
    }
  }
  NA_character_
}

# Emit one reproducibility warning per input that traces back to an
# interactive write. Wording taken verbatim from docs/design.md
# section "Interactive I/O".
.mr_warn_interactive_inputs <- function(step, inputs) {
  if (length(inputs) == 0L) return(invisible(NULL))
  con <- .mr_get_connection()
  for (pair in inputs) {
    producer <- .mr_last_producer_step(con, pair$name, pair$hash)
    if (!is.na(producer) && startsWith(producer, "<interactive:")) {
      ts <- sub("^<interactive:(.*)>$", "\\1", producer)
      warning(sprintf(
        "step '%s' grabs '%s', which was last stowed interactively on %s. This step is not fully reproducible from source.",
        basename(step), pair$name, ts
      ), call. = FALSE)
    }
  }
  invisible(NULL)
}
