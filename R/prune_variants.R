#' Delete a labeled variant
#'
#' Removes all `_mr_runs` rows for `script` whose `variant_label`
#' matches `label`. Versions the deleted runs produced fall back
#' under the normal "referenced by recent runs" protection — if a
#' downstream plain run consumed one of them, it stays; otherwise,
#' the next `prune_versions()` call is free to collect it.
#'
#' Downstream labeled variants are left alone. Tearing down a whole
#' labeled pipeline requires calling `prune_variants()` at each
#' level.
#'
#' @param script Path to the script whose variant should be removed.
#' @param label The variant label to delete.
#' @param dry_run If `TRUE`, print the summary without deleting.
#' @return The summary (`n_runs`, `run_ids`) invisibly.
#' @export
prune_variants <- function(script, label, dry_run = FALSE) {
  if (missing(script)) stop("prune_variants(): `script` is required.", call. = FALSE)
  if (missing(label))  stop("prune_variants(): `label` is required.",  call. = FALSE)
  stopifnot(is.character(script), length(script) == 1L, nzchar(script))
  stopifnot(is.character(label),  length(label)  == 1L, nzchar(label))
  step <- normalizePath(script, mustWork = FALSE)

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con,
    "SELECT run_id, started_at FROM _mr_runs
      WHERE step = ? AND variant_label = ?
      ORDER BY started_at DESC",
    params = list(step, label)
  )

  summary <- list(
    script  = step,
    label   = label,
    n_runs  = nrow(rows),
    run_ids = rows$run_id
  )

  message(sprintf(
    "prune_variants: %d run(s) matching step='%s' label='%s'%s",
    summary$n_runs, basename(step), label,
    if (dry_run) " (dry run)" else ""
  ))

  if (!dry_run && summary$n_runs > 0L) {
    .mr_execute(
      con,
      "DELETE FROM _mr_runs WHERE step = ? AND variant_label = ?",
      params = list(step, label)
    )
  }

  invisible(summary)
}
