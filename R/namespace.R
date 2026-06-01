## Namespace: one logical name -> one storage shape.
##
## Shape A = content-addressed (backed by _mr_versions).
## Shape B = run-indexed append log (backed by _mr_append_tables).

#' Look up the storage shape registered for a logical name
#'
#' @param name logical name to look up
#' @return "A" (versioned), "B" (append log), or NULL when unregistered
#' @noRd
.mr_lookup_shape <- function(name) {
  con <- .mr_get_connection()
  hit_a <- DBI::dbGetQuery(
    con,
    "SELECT 1 FROM _mr_versions WHERE logical_name = ? LIMIT 1",
    params = list(name)
  )
  if (nrow(hit_a) > 0L) return("A")
  hit_b <- DBI::dbGetQuery(
    con,
    "SELECT 1 FROM _mr_append_tables WHERE logical_name = ? LIMIT 1",
    params = list(name)
  )
  if (nrow(hit_b) > 0L) return("B")
  NULL
}

# Unified namespace guard. `shape` is the incoming shape ("A" or "B").
# `new_kind` is the within-shape kind (artifact/table/view for Shape A;
# ignored for Shape B which has only one kind).
#' Guard against re-registering a name under a conflicting shape/kind
#'
#' @param name logical name being registered
#' @param shape incoming shape, "A" or "B"
#' @param new_kind within-Shape-A kind (artifact/table/view), or NULL
#' @param context calling function name, used in error messages
#' @return invisibly NULL; stops on a shape or kind conflict
#' @noRd
.mr_guard_namespace <- function(name, shape, new_kind = NULL, context = "stow") {
  shape <- match.arg(shape, c("A", "B"))
  existing <- .mr_lookup_shape(name)
  if (is.null(existing)) return(invisible(NULL))

  if (!identical(existing, shape)) {
    stop(sprintf(
      "%s(): '%s' already exists as %s; refusing to register it as %s.",
      context, name,
      if (existing == "A") "a versioned value" else "an append table",
      if (shape == "A") "a versioned value" else "an append table"
    ), call. = FALSE)
  }

  # Within Shape A, kinds (table/view/artifact) must also match.
  if (shape == "A" && !is.null(new_kind)) {
    con <- .mr_get_connection()
    existing_kinds <- DBI::dbGetQuery(
      con,
      "SELECT DISTINCT kind FROM _mr_versions WHERE logical_name = ?",
      params = list(name)
    )$kind
    if (length(existing_kinds) > 0L && !all(existing_kinds == new_kind)) {
      stop(sprintf(
        "%s(): '%s' already exists as a %s; refusing to register it as a %s. Use a different name or prune the existing versions first.",
        context, name, existing_kinds[1], new_kind
      ), call. = FALSE)
    }
  }
  invisible(NULL)
}
