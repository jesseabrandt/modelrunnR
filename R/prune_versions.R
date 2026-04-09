#' Explicit garbage collection for stored versions
#'
#' Removes stored versions according to a policy. Without
#' `force = TRUE`, versions referenced by any `_mr_runs.outputs`
#' row are protected so that `grab(..., from_run = ...)` keeps
#' working for existing run history.
#'
#' Policy arguments combine: `keep_latest` is applied first, then
#' `keep = N`, then `older_than`. With `name = NULL` the policy
#' applies to all stored logical names.
#'
#' @param name Optional logical name to restrict pruning to.
#' @param keep Optional integer. Keep the N most recent versions
#'   (by `first_seen`) per logical name.
#' @param keep_latest Logical. If `TRUE`, keep only the single
#'   newest version per logical name.
#' @param older_than Optional character; strings like `"30d"`,
#'   `"6h"`, `"15m"`, or `"45s"`. Prunes versions whose `first_seen`
#'   is older than the parsed duration.
#' @param force Logical. If `TRUE`, also prune versions referenced
#'   by run history (destructive -- breaks `grab(from_run = ...)` for
#'   the removed versions).
#'
#' @return A data frame of the versions that were actually pruned,
#'   invisibly.
#' @export
prune_versions <- function(name = NULL,
                           keep = NULL,
                           keep_latest = FALSE,
                           older_than = NULL,
                           force = FALSE) {
  con <- .mr_get_connection()

  candidates <- if (is.null(name)) {
    DBI::dbGetQuery(con, "SELECT * FROM _mr_versions ORDER BY logical_name, first_seen")
  } else {
    DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? ORDER BY first_seen",
      params = list(name)
    )
  }
  if (nrow(candidates) == 0L) {
    return(invisible(candidates[0, , drop = FALSE]))
  }

  to_prune <- .mr_select_prune_candidates(candidates, keep, keep_latest, older_than)
  if (nrow(to_prune) == 0L) {
    return(invisible(to_prune))
  }

  protected <- if (force) character() else .mr_protected_version_hashes(con)
  keepers   <- to_prune$content_hash %in% protected
  if (any(keepers) && !force) {
    warning(sprintf(
      "%d version(s) protected from pruning because they are referenced by run history. Pass force = TRUE to prune them anyway.",
      sum(keepers)
    ), call. = FALSE)
  }
  to_prune <- to_prune[!keepers, , drop = FALSE]
  if (nrow(to_prune) == 0L) {
    return(invisible(to_prune))
  }

  for (i in seq_len(nrow(to_prune))) {
    row <- to_prune[i, , drop = FALSE]
    .mr_drop_version(con, row)
  }

  for (nm in unique(to_prune$logical_name)) {
    .mr_refresh_latest_view(con, nm)
  }

  invisible(to_prune)
}

## Internals ------------------------------------------------------------------

.mr_select_prune_candidates <- function(candidates, keep, keep_latest, older_than) {
  out <- candidates[FALSE, , drop = FALSE]
  if (nrow(candidates) == 0L) return(out)

  for (nm in unique(candidates$logical_name)) {
    rows <- candidates[candidates$logical_name == nm, , drop = FALSE]
    rows <- rows[order(rows$first_seen, decreasing = FALSE), , drop = FALSE]
    n <- nrow(rows)
    prune_mask <- rep(TRUE, n)

    if (isTRUE(keep_latest)) {
      prune_mask[n] <- FALSE
    } else if (!is.null(keep)) {
      k <- as.integer(keep)
      if (k < 0L) stop("prune_versions(): keep must be non-negative.", call. = FALSE)
      keep_idx <- seq_len(n) > max(0L, n - k)
      prune_mask <- !keep_idx
    } else if (!is.null(older_than)) {
      cutoff <- Sys.time() - .mr_parse_duration(older_than)
      prune_mask <- rows$first_seen < cutoff
    } else {
      prune_mask <- rep(FALSE, n)
    }

    if (any(prune_mask)) {
      out <- rbind(out, rows[prune_mask, , drop = FALSE])
    }
  }
  out
}

.mr_parse_duration <- function(spec) {
  m <- regmatches(spec, regexec("^([0-9]+)\\s*([smhd])$", spec))[[1]]
  if (length(m) != 3L) {
    stop(sprintf("prune_versions(): could not parse duration '%s'. Use e.g. '30d', '6h', '15m', '45s'.", spec),
         call. = FALSE)
  }
  n <- as.numeric(m[2])
  unit <- m[3]
  seconds <- switch(unit, s = n, m = n * 60, h = n * 3600, d = n * 86400)
  as.difftime(seconds, units = "secs")
}

.mr_protected_version_hashes <- function(con) {
  rows <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE outputs IS NOT NULL AND outputs <> '[]'"
  )
  if (nrow(rows) == 0L) return(character())
  hashes <- character()
  for (j in seq_len(nrow(rows))) {
    pairs <- tryCatch(
      jsonlite::fromJSON(rows$outputs[j], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) hashes <- c(hashes, p$hash)
  }
  unique(hashes)
}

.mr_drop_version <- function(con, row) {
  kind <- row$kind[1]
  if (identical(kind, "table")) {
    try(.mr_drop_table(con, row$physical_name[1]), silent = TRUE)
  } else if (identical(kind, "artifact")) {
    storage <- row$storage_location[1]
    if (identical(storage, "blob")) {
      DBI::dbExecute(
        con,
        "DELETE FROM _mr_artifacts WHERE physical_name = ?",
        params = list(row$physical_name[1])
      )
    } else if (identical(storage, "file")) {
      try(file.remove(row$physical_name[1]), silent = TRUE)
    }
  }
  DBI::dbExecute(
    con,
    "DELETE FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
    params = list(row$logical_name[1], row$content_hash[1])
  )
  invisible(NULL)
}
