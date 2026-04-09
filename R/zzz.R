## Internal package-level state.
##
## `.mr_state` holds mutable runtime state (active connection, recording
## context, rebind map) in a single internal environment so we never touch
## `.GlobalEnv` or `options()` for per-session bookkeeping.
.mr_state <- new.env(parent = emptyenv())

.onLoad <- function(libname, pkgname) {
  .mr_state$connection  <- NULL
  .mr_state$db_path     <- NULL
  .mr_state$recording   <- NULL  # list(inputs = chr(), outputs = chr()) while active
}

.onUnload <- function(libpath) {
  .mr_reset_connection()
}
