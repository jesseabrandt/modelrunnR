#' Check whether a labeled pipeline's most recent run is stale
#'
#' Exposes modelrunnR's internal staleness check so users can gate their
#' own logic on whether a re-run would be a no-op. `is_stale()` takes a
#' reference to a *labeled* pipeline, so first give a `launch()` a `label`,
#' then ask about that label with `mr_label()`:
#'
#' ```r
#' # 1. Run a pipeline under a label.
#' launch({
#'   embeddings <- embed(grab("docs"))
#'   stow(embeddings, "embeddings")
#' }, label = "embed")
#'
#' # 2. Ask whether that labeled pipeline is now stale.
#' is_stale(mr_label("embed"))
#' #> [1] FALSE
#' #> attr(,"reasons")
#' #> character(0)
#'
#' # 3. Typical use: re-run only when something changed.
#' if (is_stale(mr_label("embed"))) {
#'   launch({
#'     embeddings <- embed(grab("docs"))
#'     stow(embeddings, "embeddings")
#'   }, label = "embed")
#' }
#' ```
#'
#' For most workflows this is unnecessary — `launch()` skips fresh runs
#' automatically (see the `force` argument and the
#' `modelrunnR.skip_if_fresh` option). `is_stale()` is the explicit
#' escape hatch for the case where the user wants to branch on
#' staleness without entering `launch()` at all.
#'
#' @param ref A `mr_label()` or `mr_variant()` reference. Other
#'   reference constructors (`mr_hash`, `mr_run`, `mr_as_of`) address
#'   stored content at a point in time; they don't map to the
#'   "pipeline identity" staleness is about and error here.
#' @return A logical scalar (`TRUE` if stale, `FALSE` if fresh) with
#'   a `reasons` attribute carrying the same reason codes that
#'   `launch()`'s advisory message prints (e.g., `"never_run"`,
#'   `"code"`, `"input:<name>"`, `"external:<path>"`,
#'   `"external:env:<NAME>"`).
#' @export
is_stale <- function(ref) {
  if (!.mr_is_ref(ref) || !(identical(ref$kind, "label") ||
                            identical(ref$kind, "variant"))) {
    stop(
      "is_stale(): `ref` must be mr_label() or mr_variant(). ",
      "Other reference constructors address stored content, not pipeline identity.",
      call. = FALSE
    )
  }
  label <- ref$value

  con <- .mr_get_connection()
  prior <- DBI::dbGetQuery(
    con,
    "SELECT step FROM _mr_runs
      WHERE variant_label = ?
      ORDER BY started_at DESC LIMIT 1",
    params = list(label)
  )
  if (nrow(prior) == 0L) {
    out <- TRUE
    attr(out, "reasons") <- "never_run"
    return(out)
  }

  result <- .mr_is_stale(prior$step[1], variant_label = label)
  out <- result$stale
  attr(out, "reasons") <- result$reasons
  out
}
