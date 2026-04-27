## Session-context capture for `_mr_runs` rows.
##
## Captured once per launch (or once per interactive write) so users
## can correlate timing/staleness with machine, R version, attached
## packages, and available RAM at run start. All fields are
## best-effort: if a probe fails, we record NA and continue rather
## than blow up a launch over telemetry.

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

.mr_safe <- function(fn, fallback) {
  tryCatch(fn(), error = function(e) fallback)
}

.mr_capture_hostname <- function() {
  unname(Sys.info()[["nodename"]])
}

.mr_capture_os <- function() {
  unname(Sys.info()[["sysname"]])
}

.mr_capture_arch <- function() {
  R.version$arch
}

.mr_capture_r_version <- function() {
  paste(R.version$major, R.version$minor, sep = ".")
}

.mr_capture_n_cpu <- function() {
  as.integer(parallel::detectCores())
}

.mr_capture_total_ram <- function() {
  as.numeric(ps::ps_system_memory()$total)
}

.mr_capture_free_ram <- function() {
  as.numeric(ps::ps_system_memory()$avail)
}

# JSON of attached non-base packages at capture time. Mirrors
# `sessionInfo()$otherPkgs`. Empty list -> "[]".
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
