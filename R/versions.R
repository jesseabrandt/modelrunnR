#' List stored versions of a logical name
#'
#' Returns one row per distinct version of `name`, with the metadata
#' needed to inspect history and decide what to keep versus prune.
#' `produced_by_runs` is a list-column of the run ids that produced each
#' version (empty when the version was written outside any tracked run).
#'
#' Works on both storage shapes. For **versioned** (Shape A) names each
#' row is one `(logical_name, content_hash)` pair. For **append** (Shape
#' B) names each row is one appended chunk; `content_hash` is the
#' chunk's hash and `produced_by_runs` lists the single run that wrote
#' it. Rows are ordered **latest first** on both shapes.
#'
#' @param name A length-one character vector naming a logical value.
#'
#' @return A data frame with columns `content_hash`, `first_seen`,
#'   `last_seen`, `size_bytes`, `produced_by_runs`, ordered latest
#'   first. `size_bytes` is `NA` for Shape B rows — the value is tracked
#'   at the table level in `_mr_append_tables`, not per chunk.
#' @export
versions <- function(name) {
  .mr_validate_name(name, context = "versions")
  con <- .mr_get_connection()

  # Shape B names don't use `_mr_versions`. Each append's chunk_hash,
  # recorded in `_mr_append_chunks`, functions as the version
  # identifier. One row per append, latest first.
  if (identical(.mr_lookup_shape(name), "B")) {
    entries <- DBI::dbGetQuery(
      con,
      "SELECT run_id, started_at, chunk_hash
         FROM _mr_append_chunks
        WHERE logical_name = ?
        ORDER BY started_at DESC",
      params = list(name)
    )
    if (nrow(entries) == 0L) {
      out <- data.frame(
        content_hash = character(),
        first_seen   = as.POSIXct(character()),
        last_seen    = as.POSIXct(character()),
        size_bytes   = numeric(),
        stringsAsFactors = FALSE
      )
      out$produced_by_runs <- list()
      return(out)
    }
    out <- data.frame(
      content_hash = entries$chunk_hash,
      first_seen   = entries$started_at,
      last_seen    = entries$started_at,
      size_bytes   = rep(NA_real_, nrow(entries)),
      stringsAsFactors = FALSE
    )
    out$produced_by_runs <- as.list(entries$run_id)
    return(out)
  }

  v <- DBI::dbGetQuery(
    con,
    "SELECT content_hash, first_seen, last_seen, size_bytes
       FROM _mr_versions
      WHERE logical_name = ?
      ORDER BY first_seen DESC",
    params = list(name)
  )
  if (nrow(v) == 0L) {
    v$produced_by_runs <- list()
    return(v)
  }

  runs <- DBI::dbGetQuery(
    con,
    "SELECT run_id, outputs FROM _mr_runs WHERE outputs IS NOT NULL"
  )

  producers <- vector("list", nrow(v))
  for (i in seq_len(nrow(v))) producers[[i]] <- character()

  for (j in seq_len(nrow(runs))) {
    pairs <- tryCatch(
      jsonlite::fromJSON(runs$outputs[j], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) {
      if (identical(p$name, name)) {
        i <- which(v$content_hash == p$hash)
        if (length(i) == 1L) {
          producers[[i]] <- c(producers[[i]], runs$run_id[j])
        }
      }
    }
  }

  v$produced_by_runs <- producers
  v
}
