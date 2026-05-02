#' Discard queued runs
#'
#' Deletes rows from `_mr_runs` whose status is `"queued"`, optionally
#' filtered by variant label or start time. Useful when re-rendering a
#' qmd has accumulated stale `queue()` calls that no longer reflect the
#' source.
#'
#' Only `queued` rows are touched: completed (`success`,
#' `skipped_fresh`), failed (`error`), and `interactive` rows are left
#' alone. Use `prune()` / `prune_variants()` for those.
#'
#' @param variant_label Optional character; restrict to rows with this
#'   `variant_label`. Pass `NA` to restrict to rows with no label.
#' @param before Optional `POSIXct` (or anything `as.POSIXct`-coercible);
#'   restrict to rows where `started_at < before`.
#' @param dry_run Logical; if `TRUE`, report what would be deleted but
#'   do not delete. Default `FALSE`.
#'
#' @return Invisibly, a list with `n_runs` (rows that were or would be
#'   deleted) and `run_ids` (their ids).
#' @export
discard_queued <- function(variant_label = NULL, before = NULL, dry_run = FALSE) {
  con <- .mr_get_connection()

  where <- "status = 'queued'"
  params <- list()

  if (!is.null(variant_label)) {
    if (length(variant_label) != 1L) {
      stop("discard_queued(): `variant_label` must be length-one.",
           call. = FALSE)
    }
    if (is.na(variant_label)) {
      where <- paste(where, "AND variant_label IS NULL")
    } else {
      stopifnot(is.character(variant_label), nzchar(variant_label))
      where <- paste(where, "AND variant_label = ?")
      params <- c(params, list(variant_label))
    }
  }

  if (!is.null(before)) {
    cutoff <- tryCatch(as.POSIXct(before),
                       error = function(e) {
                         stop(sprintf("discard_queued(): could not coerce `before` to POSIXct: %s",
                                      conditionMessage(e)), call. = FALSE)
                       })
    where <- paste(where, "AND started_at < ?")
    params <- c(params, list(cutoff))
  }

  rows <- DBI::dbGetQuery(
    con,
    sprintf("SELECT run_id FROM _mr_runs WHERE %s", where),
    params = params
  )

  summary <- list(n_runs = nrow(rows), run_ids = rows$run_id)

  message(sprintf(
    "discard_queued: %d queued run(s)%s%s",
    summary$n_runs,
    if (!is.null(variant_label)) {
      sprintf(" (variant_label %s)",
              if (is.na(variant_label)) "= NULL" else sprintf("= '%s'", variant_label))
    } else "",
    if (dry_run) " (dry run)" else ""
  ))

  if (!dry_run && summary$n_runs > 0L) {
    DBI::dbBegin(con)
    tryCatch({
      DBI::dbExecute(
        con,
        sprintf("DELETE FROM _mr_runs WHERE %s", where),
        params = params
      )
      DBI::dbCommit(con)
    }, error = function(e) {
      DBI::dbRollback(con)
      stop(sprintf("discard_queued(): DELETE failed: %s", conditionMessage(e)),
           call. = FALSE)
    })
  }

  invisible(summary)
}
