## Git context capture for `_mr_runs` rows.
##
## Captured alongside session info so a run's row records which commit
## the working tree was on when it launched, and (approximately) how
## dirty that tree was. Best-effort: any failure (no `git` on PATH,
## not in a repo, transient I/O) records NA and continues -- telemetry
## must not block a launch. The dirty field is a single human-readable
## string ("3 files changed, 47 insertions(+), 12 deletions(-)") rather
## than a structured diff: enough to tell trivial tweaks from rewrites,
## without storing paths or patches.

#' Capture best-effort git context for a `_mr_runs` row
#'
#' @return a list with `git_sha`, `git_branch`, and `git_dirty`
#' @noRd
.mr_capture_git_info <- function() {
  list(
    git_sha    = .mr_safe(.mr_capture_git_sha,    NA_character_),
    git_branch = .mr_safe(.mr_capture_git_branch, NA_character_),
    git_dirty  = .mr_safe(.mr_capture_git_dirty,  NA_character_)
  )
}

#' Run a git command, returning NULL on non-zero exit
#'
#' @param args character vector of git arguments
#' @return the command's stdout lines, or NULL on failure
#' @noRd
.mr_run_git <- function(args) {
  res <- suppressWarnings(
    system2("git", args, stdout = TRUE, stderr = FALSE)
  )
  if (!is.null(attr(res, "status"))) return(NULL)
  res
}

#' Capture the current HEAD commit SHA
#'
#' @return the HEAD SHA string, or NA when unavailable
#' @noRd
.mr_capture_git_sha <- function() {
  res <- .mr_run_git(c("rev-parse", "HEAD"))
  if (is.null(res) || length(res) == 0L) return(NA_character_)
  res[[1L]]
}

#' Capture the current branch name
#'
#' @return the branch name (or "HEAD" when detached), or NA when unavailable
#' @noRd
.mr_capture_git_branch <- function() {
  res <- .mr_run_git(c("rev-parse", "--abbrev-ref", "HEAD"))
  if (is.null(res) || length(res) == 0L) return(NA_character_)
  # Detached HEAD comes back as "HEAD"; keep that signal as-is.
  res[[1L]]
}

#' Capture a human-readable working-tree dirtiness summary
#'
#' @return a summary string (diff shortstat plus untracked count), NA
#'   when clean or not a repo, or "dirty" as a generic fallback
#' @noRd
.mr_capture_git_dirty <- function() {
  status <- .mr_run_git(c("status", "--porcelain"))
  if (is.null(status)) return(NA_character_)        # not a git repo
  if (length(status) == 0L) return(NA_character_)   # clean tree -> NA

  shortstat <- .mr_run_git(c("diff", "--shortstat", "HEAD"))
  shortstat_str <- if (is.null(shortstat)) "" else trimws(paste(shortstat, collapse = " "))

  n_untracked <- sum(startsWith(status, "??"))
  untracked_str <- if (n_untracked > 0L) {
    sprintf("%d untracked", n_untracked)
  } else {
    ""
  }

  parts <- Filter(nzchar, c(shortstat_str, untracked_str))
  if (length(parts) == 0L) {
    # Dirty according to porcelain but neither tracked-diff nor untracked
    # reported it -- shouldn't happen, but record a generic flag rather
    # than NA so the dirty signal isn't lost.
    return("dirty")
  }
  paste(parts, collapse = ", ")
}
