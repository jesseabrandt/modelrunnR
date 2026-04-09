## Project-root detection.
##
## Walks up from `start` looking for any of the markers listed in
## `.mr_project_markers()`. Returns the first directory that contains
## one, or NULL if none is found before reaching the filesystem root
## (or `stop_at`, used by tests to bound the walk).
##
## Kept internal (~20 LOC, no external deps) per docs/design.md
## §"Connection and project layout".

.mr_project_markers <- function() {
  c("DESCRIPTION", ".Rproj", ".git/", "renv.lock", ".here")
}

.mr_has_marker <- function(dir) {
  for (m in .mr_project_markers()) {
    if (identical(m, ".git/")) {
      if (dir.exists(file.path(dir, ".git"))) return(TRUE)
    } else if (identical(m, ".Rproj")) {
      # .Rproj is an extension, not a file name — look for any *.Rproj.
      # all.files = TRUE so literal ".Rproj" (a dotfile) is matched too.
      if (length(list.files(dir, pattern = "\\.Rproj$", all.files = TRUE)) > 0L) return(TRUE)
    } else {
      if (file.exists(file.path(dir, m))) return(TRUE)
    }
  }
  FALSE
}

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
