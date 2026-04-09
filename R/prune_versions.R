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
  # `keep_latest` is a shorthand for `keep = 1`; passing both is an
  # overlapping-intent error (unlike `keep` + `older_than`, which combine
  # naturally as a union of prune masks).
  if (isTRUE(keep_latest) && !is.null(keep)) {
    stop("prune_versions(): pass either `keep_latest` or `keep`, not both.",
         call. = FALSE)
  }

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

  protected <- if (force) {
    data.frame(name = character(), hash = character(), stringsAsFactors = FALSE)
  } else {
    .mr_protected_version_hashes(con)
  }
  # Membership test must be on (name, hash) PAIRS, not on hash alone:
  # two different logical names can happen to share a content hash, and
  # keying on hash alone lets one name's protection cross-contaminate
  # the other. \x1f (unit separator) cannot appear in names (rejected by
  # .mr_validate_name in slice 3) or in hex hashes, so it's a safe
  # delimiter for the string-concatenation key.
  key <- paste0(to_prune$logical_name, "\x1f", to_prune$content_hash)
  protected_key <- paste0(protected$name, "\x1f", protected$hash)
  keepers <- key %in% protected_key
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

  # Tidy up: if we pruned filesystem artifacts and the artifact dir is
  # now empty, remove it so we don't leave orphan directories.
  artifact_dir <- file.path(dirname(db_path()), "modelrunnR_artifacts")
  if (dir.exists(artifact_dir) &&
      length(list.files(artifact_dir, all.files = FALSE)) == 0L) {
    unlink(artifact_dir, recursive = FALSE)
  }

  invisible(to_prune)
}

## Internals ------------------------------------------------------------------

.mr_select_prune_candidates <- function(candidates, keep, keep_latest, older_than) {
  out <- candidates[FALSE, , drop = FALSE]
  if (nrow(candidates) == 0L) return(out)

  # Policy masks combine as a UNION: a version is pruned if any active
  # policy says so. No active policy -> nothing is pruned.
  for (nm in unique(candidates$logical_name)) {
    rows <- candidates[candidates$logical_name == nm, , drop = FALSE]
    rows <- rows[order(rows$first_seen, decreasing = FALSE), , drop = FALSE]
    n <- nrow(rows)
    prune_mask <- rep(FALSE, n)

    if (isTRUE(keep_latest)) {
      # keep_latest: prune everything except the newest row
      prune_mask <- prune_mask | (seq_len(n) != n)
    }
    if (!is.null(keep)) {
      k <- as.integer(keep)
      if (k < 0L) stop("prune_versions(): keep must be non-negative.", call. = FALSE)
      # keep: prune rows that are NOT in the newest `k`
      prune_mask <- prune_mask | !(seq_len(n) > max(0L, n - k))
    }
    if (!is.null(older_than)) {
      cutoff <- Sys.time() - .mr_parse_duration(older_than)
      prune_mask <- prune_mask | (rows$first_seen < cutoff)
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
  empty <- data.frame(name = character(), hash = character(),
                      stringsAsFactors = FALSE)
  if (nrow(rows) == 0L) return(empty)
  names_out  <- character()
  hashes_out <- character()
  for (j in seq_len(nrow(rows))) {
    pairs <- tryCatch(
      jsonlite::fromJSON(rows$outputs[j], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) {
      nm <- p$name %||% NA_character_
      hs <- p$hash %||% NA_character_
      names_out  <- c(names_out,  nm)
      hashes_out <- c(hashes_out, hs)
    }
  }
  df <- data.frame(name = names_out, hash = hashes_out,
                   stringsAsFactors = FALSE)
  unique(df)
}

.mr_drop_version <- function(con, row) {
  kind <- row$kind[1]
  storage <- row$storage_location[1]

  # Atomic drop: the physical drop and the metadata delete must both
  # succeed or both roll back. Previously, silent `try()` on the
  # physical drop could leave an orphaned file/table while the metadata
  # row was deleted unconditionally, hiding corruption.
  DBI::dbBegin(con)
  tryCatch({
    if (identical(kind, "table")) {
      .mr_drop_table(con, row$physical_name[1])
    } else if (identical(kind, "artifact")) {
      if (identical(storage, "blob")) {
        DBI::dbExecute(
          con,
          "DELETE FROM _mr_artifacts WHERE physical_name = ?",
          params = list(row$physical_name[1])
        )
      } else if (identical(storage, "file")) {
        # file.remove returns FALSE rather than erroring on failure, so
        # check explicitly and raise so the transaction rolls back.
        if (file.exists(row$physical_name[1]) &&
            !isTRUE(file.remove(row$physical_name[1]))) {
          stop(sprintf("prune_versions(): failed to remove file artifact '%s'",
                       row$physical_name[1]),
               call. = FALSE)
        }
      }
    }
    DBI::dbExecute(
      con,
      "DELETE FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
      params = list(row$logical_name[1], row$content_hash[1])
    )
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    warning(sprintf(
      "prune_versions(): could not drop '%s' @ %s: %s",
      row$logical_name[1], substr(row$content_hash[1], 1L, 12L),
      conditionMessage(e)
    ), call. = FALSE)
  })
  invisible(NULL)
}
