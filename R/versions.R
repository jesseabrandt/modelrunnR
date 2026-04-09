#' List stored versions of a logical name
#'
#' Returns one row per distinct `(logical_name, content_hash)` pair
#' for `name`, with the metadata needed to inspect history and decide
#' what to keep versus prune. `produced_by_runs` is a list-column of
#' the run ids that produced each version (empty when the version was
#' written outside any tracked run).
#'
#' @param name A length-one character vector naming a logical value.
#'
#' @return A data frame with columns `content_hash`, `first_seen`,
#'   `last_seen`, `size_bytes`, `produced_by_runs`, ordered by
#'   `first_seen`.
#' @export
versions <- function(name) {
  .mr_validate_name(name, context = "versions")
  con <- .mr_get_connection()

  v <- DBI::dbGetQuery(
    con,
    "SELECT content_hash, first_seen, last_seen, size_bytes
       FROM _mr_versions
      WHERE logical_name = ?
      ORDER BY first_seen",
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
