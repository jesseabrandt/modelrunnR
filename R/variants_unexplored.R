#' Labeled upstream variants not yet consumed by a script
#'
#' For each `grab()` the script has historically made, returns the
#' set of labeled upstream variants that have produced that name and
#' a flag indicating whether any run of this script has consumed
#' that specific upstream hash.
#'
#' @param script Path to the consumer script.
#' @return A data frame with columns `logical_name`, `upstream_label`,
#'   `upstream_hash`, `last_seen`, `used_by_this_script`.
#' @export
variants_unexplored <- function(script) {
  stopifnot(is.character(script), length(script) == 1L, nzchar(script))
  step <- normalizePath(script, mustWork = FALSE)
  con  <- .mr_get_connection()

  # 1. Which logical names does this script grab historically?
  input_rows <- DBI::dbGetQuery(
    con, "SELECT inputs FROM _mr_runs WHERE step = ?", params = list(step)
  )
  input_names <- unique(unlist(lapply(input_rows$inputs, function(js) {
    if (is.na(js) || !nzchar(js)) return(character())
    vapply(jsonlite::fromJSON(js, simplifyVector = FALSE),
           function(p) p$name, character(1))
  })))

  if (length(input_names) == 0L) {
    return(data.frame(
      logical_name = character(), upstream_label = character(),
      upstream_hash = character(), last_seen = as.POSIXct(character()),
      used_by_this_script = logical(),
      stringsAsFactors = FALSE
    ))
  }

  # 2. For each logical name, find labeled upstream hashes that have
  #    been produced for it and when.
  # Fetch labeled-upstream rows once — the result doesn't depend on
  # the per-input-name loop variable.
  rows <- DBI::dbGetQuery(
    con,
    "SELECT variant_label, outputs, started_at
       FROM _mr_runs
      WHERE variant_label IS NOT NULL"
  )

  upstreams <- list()
  for (nm in input_names) {
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
        if (identical(p$name, nm)) {
          upstreams[[length(upstreams) + 1L]] <- data.frame(
            logical_name   = nm,
            upstream_label = rows$variant_label[j],
            upstream_hash  = p$hash,
            last_seen      = rows$started_at[j],
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }
  if (length(upstreams) == 0L) {
    return(data.frame(
      logical_name = character(), upstream_label = character(),
      upstream_hash = character(), last_seen = as.POSIXct(character()),
      used_by_this_script = logical(),
      stringsAsFactors = FALSE
    ))
  }
  out <- do.call(rbind, upstreams)
  # Dedup by (name, label, hash) and keep latest last_seen.
  ord <- order(out$last_seen, decreasing = TRUE)
  out <- out[ord, , drop = FALSE]
  key <- paste(out$logical_name, out$upstream_label, out$upstream_hash)
  out <- out[!duplicated(key), , drop = FALSE]

  # 3. Mark which upstream hashes this script has consumed.
  used_pairs <- do.call(c, lapply(input_rows$inputs, function(js) {
    if (is.na(js) || !nzchar(js)) return(character())
    vapply(jsonlite::fromJSON(js, simplifyVector = FALSE),
           function(p) paste(p$name, p$hash), character(1))
  }))
  out$used_by_this_script <- paste(out$logical_name, out$upstream_hash) %in% used_pairs

  rownames(out) <- NULL
  out
}
