#' Reference constructors for `launch(rebind = list(...))`
#'
#' Small, structured wrappers for addressing existing modelrunnR
#' versions by identity instead of inlining R values in
#' `launch(rebind = list(...))`. Each returns a tagged list that
#' `launch()` resolves to a content hash before recording starts.
#'
#' Use a bare R value in `rebind` when you want the value stowed
#' inline; use one of these constructors when you want to address
#' something already stored.
#'
#' @param hash A content hash string (from `versions()`).
#' @param run_id A run id string (from `_mr_runs`).
#' @param label A variant label string.
#' @param time A timestamp (`POSIXct`) or a string parseable by
#'   `as.POSIXct`.
#' @return A tagged list for `launch()` to resolve.
#' @name references
NULL

#' @rdname references
#' @export
mr_hash <- function(hash) {
  stopifnot(is.character(hash), length(hash) == 1L, nzchar(hash))
  structure(list(kind = "hash", value = hash), class = "mr_ref")
}

#' @rdname references
#' @export
mr_run <- function(run_id) {
  stopifnot(is.character(run_id), length(run_id) == 1L, nzchar(run_id))
  structure(list(kind = "run", value = run_id), class = "mr_ref")
}

#' @rdname references
#' @export
mr_variant <- function(label) {
  stopifnot(is.character(label), length(label) == 1L, nzchar(label))
  structure(list(kind = "variant", value = label), class = "mr_ref")
}

#' @rdname references
#' @export
mr_as_of <- function(time) {
  # Parse string timestamps as UTC for reproducibility — DuckDB
  # TIMESTAMP columns are timezone-naive, and the session TZ could
  # otherwise shift which version this resolves to across machines.
  if (is.character(time)) time <- as.POSIXct(time, tz = "UTC")
  stopifnot(inherits(time, "POSIXct"), length(time) == 1L)
  structure(list(kind = "as_of", value = time), class = "mr_ref")
}

.mr_is_ref <- function(x) inherits(x, "mr_ref")
