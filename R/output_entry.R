## Shape discriminator for `_mr_runs.outputs` JSON entries.
##
## An output entry is one of two shapes:
##   - versioned-shape (Shape A): {name, hash}
##   - append-shape   (Shape B): {kind = "append_table", logical_name,
##                                rows_appended, chunk_hash}
##
## Callers match by logical name — sometimes also narrowed by hash for
## shape A — across both shapes uniformly.

# Return TRUE if `entry` names the given logical `name`. When `hash` is
# non-NULL and non-NA, additionally require a hash match on shape-A
# entries; shape-B entries are unaffected by `hash` (an append log has
# no single content hash).
#' Test whether an output entry matches a logical name (and optional hash)
#'
#' @param entry an output JSON entry (Shape A or Shape B)
#' @param name logical name to match
#' @param hash optional content hash; narrows Shape A matches when set
#' @return TRUE when the entry matches, else FALSE
#' @noRd
.mr_output_matches_name <- function(entry, name, hash = NULL) {
  if (identical(entry$kind, "append_table")) {
    return(identical(entry$logical_name, name))
  }
  if (!identical(entry$name, name)) return(FALSE)
  if (is.null(hash) || is.na(hash)) return(TRUE)
  identical(entry$hash, hash)
}
