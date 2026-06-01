## Internal package-level state.
##
## `.mr_state` holds mutable runtime state (active connection, recording
## context, rebind map) in a single internal environment so we never touch
## `.GlobalEnv` or `options()` for per-session bookkeeping.
.mr_state <- new.env(parent = emptyenv())

#' Package load hook: initialize `.mr_state` runtime fields
#'
#' @param libname library path where the package is installed
#' @param pkgname package name
#' @return invisibly NULL
#' @noRd
.onLoad <- function(libname, pkgname) {
  .mr_state$connection  <- NULL
  .mr_state$db_path     <- NULL
  .mr_state$recording   <- NULL  # list(inputs, outputs, n_grabs, n_stows, run_id, variant_label) while active
}

#' Package unload hook: close the cached connection
#'
#' @param libpath library path where the package is installed
#' @return invisibly NULL
#' @noRd
.onUnload <- function(libpath) {
  .mr_reset_connection()
}
