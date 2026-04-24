#' Prune rows from run-indexed append logs (Shape B)
#'
#' Removes rows from append tables by run id or age. The registry row
#' in `_mr_append_tables` is preserved even when all rows are removed,
#' so the accumulator continues to exist (empty) under its logical name.
#'
#' Rows whose run has a non-null `variant_label` are protected unless
#' `force = TRUE`.
#'
#' @param name Optional logical name to restrict pruning to.
#' @param run_id Optional run id (single string or character vector) —
#'   prune rows produced by those runs.
#' @param older_than Optional duration string (e.g. `"30d"`, `"6h"`)
#'   — prune rows whose run started before now - <duration>.
#' @param keep Optional integer. Keep the N most recent runs per
#'   logical name; prune rows from older runs.
#' @param force Logical. If `TRUE`, also prune variant-labeled rows.
#' @return A data frame of per-name pruning summaries, invisibly.
#' @export
prune_runs <- function(name = NULL,
                       run_id = NULL,
                       older_than = NULL,
                       keep = NULL,
                       force = FALSE) {
  if (!is.null(name)) .mr_validate_name(name, context = "prune_runs")
  con <- .mr_get_connection()

  targets <- if (is.null(name)) {
    DBI::dbGetQuery(con, "SELECT * FROM _mr_append_tables")
  } else {
    DBI::dbGetQuery(con,
      "SELECT * FROM _mr_append_tables WHERE logical_name = ?",
      params = list(name))
  }
  if (nrow(targets) == 0L) {
    return(invisible(data.frame(logical_name = character(),
                                rows_pruned  = integer(),
                                stringsAsFactors = FALSE)))
  }

  cutoff <- if (!is.null(older_than)) {
    Sys.time() - .mr_parse_duration(older_than)
  } else NULL

  summaries <- vector("list", nrow(targets))
  for (i in seq_len(nrow(targets))) {
    row <- targets[i, , drop = FALSE]
    summaries[[i]] <- .mr_prune_runs_one(con, row, run_id, cutoff, keep, force)
  }
  invisible(do.call(rbind, summaries))
}

.mr_prune_runs_one <- function(con, registry_row, run_id, cutoff, keep, force) {
  logical  <- registry_row$logical_name[1]
  physical <- registry_row$physical_name[1]

  all_runs_sql <- sprintf("SELECT DISTINCT _mr_run_id AS rid FROM %s",
                          .mr_quote_ident(physical))
  all_runs <- DBI::dbGetQuery(con, all_runs_sql)
  if (nrow(all_runs) == 0L) {
    return(data.frame(logical_name = logical, rows_pruned = 0L,
                      stringsAsFactors = FALSE))
  }

  ids_to_prune <- character()
  if (!is.null(run_id)) {
    ids_to_prune <- c(ids_to_prune, as.character(run_id))
  }

  quote_list <- function(ids) {
    paste(vapply(ids, function(x) DBI::dbQuoteLiteral(con, x),
                 character(1)),
          collapse = ", ")
  }

  if (!is.null(cutoff)) {
    rids <- DBI::dbGetQuery(
      con,
      sprintf(
        "SELECT run_id FROM _mr_runs
          WHERE started_at < ? AND run_id IN (%s)",
        quote_list(all_runs$rid)
      ),
      params = list(cutoff))
    ids_to_prune <- c(ids_to_prune, rids$run_id)
  }

  if (!is.null(keep) && is.numeric(keep) && keep >= 0) {
    ranked <- DBI::dbGetQuery(
      con,
      sprintf(
        "SELECT run_id FROM _mr_runs
          WHERE run_id IN (%s)
          ORDER BY started_at DESC",
        quote_list(all_runs$rid)
      )
    )
    if (nrow(ranked) > keep) {
      ids_to_prune <- c(ids_to_prune, ranked$run_id[(keep + 1L):nrow(ranked)])
    }
  }

  ids_to_prune <- unique(ids_to_prune)
  if (length(ids_to_prune) == 0L) {
    return(data.frame(logical_name = logical, rows_pruned = 0L,
                      stringsAsFactors = FALSE))
  }

  if (!isTRUE(force)) {
    labeled <- DBI::dbGetQuery(
      con,
      sprintf(
        "SELECT run_id FROM _mr_runs
          WHERE variant_label IS NOT NULL AND run_id IN (%s)",
        quote_list(ids_to_prune)
      )
    )
    ids_to_prune <- setdiff(ids_to_prune, labeled$run_id)
    if (length(labeled$run_id) > 0L) {
      warning(sprintf(
        "%d variant-labeled run(s) protected; pass force = TRUE to prune.",
        length(labeled$run_id)), call. = FALSE)
    }
    if (length(ids_to_prune) == 0L) {
      return(data.frame(logical_name = logical, rows_pruned = 0L,
                        stringsAsFactors = FALSE))
    }
  }

  count_sql <- sprintf(
    "SELECT COUNT(*) AS c FROM %s WHERE _mr_run_id IN (%s)",
    .mr_quote_ident(physical), quote_list(ids_to_prune))
  count <- DBI::dbGetQuery(con, count_sql)$c[1]

  DBI::dbBegin(con)
  tryCatch({
    DBI::dbExecute(con,
      sprintf("DELETE FROM %s WHERE _mr_run_id IN (%s)",
              .mr_quote_ident(physical), quote_list(ids_to_prune)))
    DBI::dbExecute(con,
      "UPDATE _mr_append_tables
          SET row_count = row_count - ?, last_seen = ?
        WHERE logical_name = ?",
      params = list(count, Sys.time(), logical))
    DBI::dbCommit(con)
  }, error = function(e) { DBI::dbRollback(con); stop(e) })

  data.frame(logical_name = logical, rows_pruned = as.integer(count),
             stringsAsFactors = FALSE)
}
