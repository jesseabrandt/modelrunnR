## Session-context capture for `_mr_runs` rows.
##
## Captured once per launch (or once per interactive write) so users
## can correlate timing/staleness with machine, R version, attached
## packages, and available RAM at run start. All fields are
## best-effort: if a probe fails, we record NA and continue rather
## than blow up a launch over telemetry.

#' Capture best-effort session context for a `_mr_runs` row
#'
#' @return a list of host/OS/arch/R/CPU/RAM/package and git fields
#' @noRd
.mr_capture_session_info <- function() {
  c(
    list(
      hostname          = .mr_safe(.mr_capture_hostname,   NA_character_),
      os                = .mr_safe(.mr_capture_os,         NA_character_),
      arch              = .mr_safe(.mr_capture_arch,       NA_character_),
      r_version         = .mr_safe(.mr_capture_r_version,  NA_character_),
      n_cpu             = .mr_safe(.mr_capture_n_cpu,      NA_integer_),
      total_ram_bytes   = .mr_safe(.mr_capture_total_ram,  NA_real_),
      free_ram_bytes    = .mr_safe(.mr_capture_free_ram,   NA_real_),
      attached_packages = .mr_safe(.mr_capture_attached,   "[]")
    ),
    .mr_capture_git_info()
  )
}

#' Call a probe function, returning a fallback on error
#'
#' @param fn zero-arg function to evaluate
#' @param fallback value returned if `fn` errors
#' @return `fn()`'s result, or `fallback` on error
#' @noRd
.mr_safe <- function(fn, fallback) {
  tryCatch(fn(), error = function(e) fallback)
}

#' Capture the machine hostname
#'
#' @return the node name string
#' @noRd
.mr_capture_hostname <- function() {
  unname(Sys.info()[["nodename"]])
}

#' Capture the operating system name
#'
#' @return the system name string
#' @noRd
.mr_capture_os <- function() {
  unname(Sys.info()[["sysname"]])
}

#' Capture the R build architecture
#'
#' @return the architecture string
#' @noRd
.mr_capture_arch <- function() {
  R.version$arch
}

#' Capture the running R version as `major.minor`
#'
#' @return the R version string
#' @noRd
.mr_capture_r_version <- function() {
  paste(R.version$major, R.version$minor, sep = ".")
}

#' Capture the number of detected CPU cores
#'
#' @return the core count as an integer
#' @noRd
.mr_capture_n_cpu <- function() {
  as.integer(parallel::detectCores())
}

#' Capture total system RAM in bytes
#'
#' @return total RAM as a numeric byte count
#' @noRd
.mr_capture_total_ram <- function() {
  as.numeric(ps::ps_system_memory()$total)
}

#' Capture available system RAM in bytes
#'
#' @return available RAM as a numeric byte count
#' @noRd
.mr_capture_free_ram <- function() {
  as.numeric(ps::ps_system_memory()$avail)
}

# JSON of attached non-base packages at capture time. Mirrors
# `sessionInfo()$otherPkgs`. Empty list -> "[]".
#' Capture attached non-base packages as a JSON array
#'
#' @return JSON string of `{pkg, ver}` entries, or "[]" when none
#' @noRd
.mr_capture_attached <- function() {
  info <- utils::sessionInfo()
  pkgs <- info$otherPkgs
  if (length(pkgs) == 0L) return("[]")
  entries <- lapply(pkgs, function(p) {
    list(pkg = p$Package, ver = p$Version)
  })
  names(entries) <- NULL
  jsonlite::toJSON(entries, auto_unbox = TRUE)
}
