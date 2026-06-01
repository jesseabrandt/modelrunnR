## Auto-propagation of variant labels from upstream grabs.
##
## Called from launch() after source() returns, given the observed
## input pairs of the finished run. Returns one of:
##   - a single label string: downstream inherits it
##   - NA_character_: downstream is plain, no disagreement
##   - structure(NA_character_, disagreement = list(...)): plain +
##     the caller should emit an ambiguous-upstreams warning
##
## The disagreement structure names the names that resolved to
## distinct labels so the warning message can surface them.

#' Derive a downstream variant label from upstream input labels
#'
#' @param con DuckDB connection
#' @param inputs list of observed `{name, hash}` input pairs
#' @return the single inherited label, NA when none, or NA with a
#'   `disagreement` attribute when upstreams conflict
#' @noRd
.mr_propagate_label <- function(con, inputs) {
  if (length(inputs) == 0L) return(NA_character_)

  # For each observed input {name, hash}, look up the producing run's
  # variant_label via _mr_runs.outputs.
  labels_by_name <- list()
  for (p in inputs) {
    label <- .mr_label_for_produced_hash(con, p$name, p$hash)
    if (!is.na(label)) {
      labels_by_name[[p$name]] <- label
    }
  }

  if (length(labels_by_name) == 0L) return(NA_character_)
  uniq <- unique(unlist(labels_by_name))
  if (length(uniq) == 1L) return(uniq)

  structure(NA_character_, disagreement = labels_by_name)
}

#' Look up the variant label of the run that produced `(name, hash)`
#'
#' @param con DuckDB connection
#' @param name logical name to match
#' @param hash content hash to match
#' @return the producing run's variant_label, or NA when none matches
#' @noRd
.mr_label_for_produced_hash <- function(con, name, hash) {
  # Find the most recent run that produced (name, hash) and return
  # its variant_label. NULL if no producing run or NA label.
  rows <- DBI::dbGetQuery(
    con,
    "SELECT variant_label, outputs FROM _mr_runs
      WHERE variant_label IS NOT NULL
      ORDER BY started_at DESC"
  )
  for (j in seq_len(nrow(rows))) {
    raw <- rows$outputs[j]
    pairs <- if (is.na(raw) || !nzchar(raw)) {
      list()
    } else {
      tryCatch(
        jsonlite::fromJSON(raw, simplifyVector = FALSE),
        error = function(e) list()
      )
    }
    for (p in pairs) {
      if (.mr_output_matches_name(p, name, hash)) {
        return(rows$variant_label[j])
      }
    }
  }
  NA_character_
}

#' Find the first input whose producing run carried a target label
#'
#' @param inputs list of `{name, hash}` input pairs
#' @param con DuckDB connection
#' @param target_label variant label to match against
#' @return the matching input's name, or NA when none matches
#' @noRd
.mr_first_input_producing <- function(inputs, con, target_label) {
  for (p in inputs) {
    if (identical(.mr_label_for_produced_hash(con, p$name, p$hash), target_label)) {
      return(p$name)
    }
  }
  NA_character_
}
