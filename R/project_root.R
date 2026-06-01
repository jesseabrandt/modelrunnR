## Project-root detection.
##
## Walks up from `start` looking for any of the markers listed in
## `.mr_project_markers()`. Returns the first directory that contains
## one, or NULL if none is found before reaching the filesystem root
## (or `stop_at`, used by tests to bound the walk).
##
## Kept internal (~20 LOC, no external deps) per docs/design.md
## section "Connection and project layout".

#' List the filenames/markers that denote a project root
#'
#' @return a character vector of marker names
#' @noRd
.mr_project_markers <- function() {
  c("DESCRIPTION", ".Rproj", ".git/", "renv.lock", ".here")
}

#' Test whether a directory contains any project-root marker
#'
#' @param dir directory to check
#' @return TRUE if any marker is present, else FALSE
#' @noRd
.mr_has_marker <- function(dir) {
  for (m in .mr_project_markers()) {
    if (identical(m, ".git/")) {
      if (dir.exists(file.path(dir, ".git"))) return(TRUE)
    } else if (identical(m, ".Rproj")) {
      # .Rproj is an extension, not a file name -- look for any *.Rproj.
      # all.files = TRUE so literal ".Rproj" (a dotfile) is matched too.
      if (length(list.files(dir, pattern = "\\.Rproj$", all.files = TRUE)) > 0L) return(TRUE)
    } else {
      if (file.exists(file.path(dir, m))) return(TRUE)
    }
  }
  FALSE
}

#' Walk up from a directory to find the project root
#'
#' @param start directory to start the upward walk from
#' @param stop_at optional boundary directory that bounds the walk
#' @return the first directory containing a marker, or NULL if none
#' @noRd
.mr_project_root <- function(start = getwd(),
                             stop_at = getOption("modelrunnR.project_stop_at", NULL)) {
  dir <- normalizePath(start, mustWork = FALSE)
  if (!is.null(stop_at)) {
    stop_at <- normalizePath(stop_at, mustWork = FALSE)
  }
  repeat {
    if (.mr_has_marker(dir)) return(dir)
    parent <- dirname(dir)
    # Reached filesystem root or explicit stop boundary.
    if (identical(parent, dir)) return(NULL)
    if (!is.null(stop_at) && identical(dir, stop_at)) return(NULL)
    dir <- parent
  }
}
