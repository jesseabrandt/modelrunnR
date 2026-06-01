#' Build a batch of `launch(rebind = ...)` envelopes
#'
#' Pure list constructor for a sweep of rebinds. Each named `...`
#' argument is the vector of values for that rebind slot. Pass the
#' returned object to `launch(rebind = ...)` and the launch fans out
#' into one run per envelope.
#'
#' Two expansion modes:
#'
#' * `mode = "zip"` (default) -- element-wise pairing. All `...`
#'   arguments must share one length N (length-1 recycles to N).
#' * `mode = "cross"` -- Cartesian product. N = product of lengths.
#'
#' Values flow through unchanged: pass `mr_variant("clean")` to
#' resolve to a labeled variant's latest hash, `mr_hash("...")` to
#' address a specific version, or a bare R value to stow inline. If
#' you want to sweep over variant labels, use `mr_variants(...)` to
#' avoid passing bare strings as literal values.
#'
#' Optional `.labels` is a character vector (length N after expansion)
#' of explicit labels for the runs. When `NULL` (default), labels are
#' left unset and the existing label-auto-propagation path fills them
#' from upstream variants.
#'
#' @param ... Named sweep arguments. Each value is a vector / list of
#'   per-envelope values for that rebind slot.
#' @param mode `"zip"` (element-wise) or `"cross"` (Cartesian product).
#' @param .labels Optional character vector of explicit labels (one per
#'   envelope after expansion).
#' @return An `mr_binds` object: a classed list of envelope lists, each
#'   suitable as the `rebind =` value of a single `launch()`.
#' @seealso [mr_variants()] for sweeping over variant labels;
#'   [mr_envelopes()] for hand-built envelopes when `mr_binds()`'s
#'   sweep API isn't expressive enough.
#' @export
mr_binds <- function(..., mode = c("zip", "cross"), .labels = NULL) {
  args <- list(...)
  mode <- match.arg(mode)
  if (length(args) == 0L) {
    stop("mr_binds(): supply at least one named sweep argument.", call. = FALSE)
  }
  if (is.null(names(args)) || any(!nzchar(names(args)))) {
    stop("mr_binds(): all `...` arguments must be named.", call. = FALSE)
  }

  # Coerce each slot to a list (so length()/[[ semantics work uniformly
  # whether the user passed an atomic vector or a list of refs).
  slots <- lapply(args, function(x) if (is.list(x)) x else as.list(x))
  lens  <- vapply(slots, length, integer(1))

  envelopes <- if (identical(mode, "zip")) {
    .mr_binds_zip(slots, lens)
  } else {
    .mr_binds_cross(slots, lens)
  }

  if (!is.null(.labels)) {
    if (!is.character(.labels) || any(is.na(.labels))) {
      stop("mr_binds(): `.labels` must be a non-NA character vector.",
           call. = FALSE)
    }
    if (length(.labels) != length(envelopes)) {
      stop(sprintf(
        "mr_binds(): `.labels` length (%d) must equal envelope count (%d).",
        length(.labels), length(envelopes)
      ), call. = FALSE)
    }
    for (k in seq_along(envelopes)) {
      envelopes[[k]]$.label <- .labels[[k]]
    }
  }

  structure(envelopes, class = "mr_binds", mode = mode)
}

# Element-wise pairing. Every slot must share a length, with length-1
# slots recycling. Errors on any other length mismatch.
#' Expand sweep slots by element-wise (zip) pairing
#'
#' @param slots Named list of per-slot value lists.
#' @param lens Integer vector of slot lengths.
#' @return A list of N envelopes; errors on incompatible lengths.
#' @noRd
.mr_binds_zip <- function(slots, lens) {
  non_one <- lens[lens != 1L]
  N <- if (length(non_one) == 0L) 1L else non_one[[1L]]
  if (any(non_one != N)) {
    odd <- names(non_one)[non_one != N]
    stop(sprintf(
      "mr_binds(mode = 'zip'): all slots must share length %d (or 1); odd lengths: %s.",
      N,
      paste(sprintf("%s=%d", odd, non_one[odd]), collapse = ", ")
    ), call. = FALSE)
  }
  envelopes <- vector("list", N)
  for (k in seq_len(N)) {
    env <- list()
    for (nm in names(slots)) {
      env[[nm]] <- if (lens[[nm]] == 1L) slots[[nm]][[1L]] else slots[[nm]][[k]]
    }
    envelopes[[k]] <- env
  }
  envelopes
}

# Cartesian product of all slots. N = prod(lens). Iteration order
# matches expand.grid()'s convention: the FIRST slot varies fastest.
#' Expand sweep slots by Cartesian product (cross)
#'
#' @param slots Named list of per-slot value lists.
#' @param lens Integer vector of slot lengths.
#' @return A list of `prod(lens)` envelopes; errors on any zero-length
#'   slot.
#' @noRd
.mr_binds_cross <- function(slots, lens) {
  if (any(lens == 0L)) {
    stop("mr_binds(mode = 'cross'): zero-length slot would produce zero envelopes.",
         call. = FALSE)
  }
  N <- prod(lens)
  envelopes <- vector("list", N)
  # Generate index combinations via expand.grid for clarity (small N
  # in practice; sweeps are < a few hundred).
  idx_grid <- do.call(
    expand.grid,
    c(lapply(lens, seq_len),
      list(KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE))
  )
  for (k in seq_len(N)) {
    env <- list()
    for (nm in names(slots)) {
      env[[nm]] <- slots[[nm]][[idx_grid[[nm]][k]]]
    }
    envelopes[[k]] <- env
  }
  envelopes
}

#' Build a vector of variant references
#'
#' Convenience for `mr_binds(<name> = mr_variants("clean", "raw"))` so
#' bare strings aren't accidentally passed as literal rebind values.
#' Equivalent to `list(mr_variant("clean"), mr_variant("raw"))`.
#'
#' Sibling helpers (`mr_hashes`, `mr_runs`, `mr_as_ofs`) are not
#' provided in v0.1; ship on demand.
#'
#' @param ... Bare strings naming variants.
#' @return A list of `mr_variant` references.
#' @seealso [mr_binds()] for the sweep constructor that consumes this;
#'   [mr_variant()] for the single-reference form.
#' @export
mr_variants <- function(...) {
  args <- list(...)
  if (length(args) == 0L) {
    stop("mr_variants(): supply at least one variant label.", call. = FALSE)
  }
  if (!all(vapply(args, function(x) is.character(x) && length(x) == 1L &&
                    !is.na(x) && nzchar(x), logical(1)))) {
    stop("mr_variants(): all arguments must be non-empty character strings.",
         call. = FALSE)
  }
  lapply(args, mr_variant)
}

#' Build batch envelopes by hand
#'
#' Primitive constructor under `mr_binds()`. Use this when you want
#' per-envelope `.label`, mixed reference kinds across envelopes, or
#' any other shape that the simpler `mr_binds()` sweep API doesn't
#' express.
#'
#' Each `...` argument is a named list. A `.label` field, if present,
#' is the explicit run label for that envelope; all other names are
#' rebind slots (their values flow through resolution unchanged, exactly
#' like values inside `launch(rebind = list(...))`).
#'
#' @param ... One or more named lists, each describing a single
#'   envelope.
#' @return An `mr_binds` object.
#' @seealso [mr_binds()] is the sugared form; reach for `mr_envelopes()`
#'   only when you need per-envelope `.label` or mixed reference kinds
#'   across envelopes.
#' @export
mr_envelopes <- function(...) {
  envelopes <- list(...)
  if (length(envelopes) == 0L) {
    stop("mr_envelopes(): supply at least one envelope.", call. = FALSE)
  }
  for (k in seq_along(envelopes)) {
    env <- envelopes[[k]]
    if (!is.list(env) || is.null(names(env)) || any(!nzchar(names(env)))) {
      stop(sprintf(
        "mr_envelopes(): envelope %d must be a fully-named list.", k
      ), call. = FALSE)
    }
    if (".label" %in% names(env)) {
      lbl <- env$.label
      if (!is.character(lbl) || length(lbl) != 1L || is.na(lbl) || !nzchar(trimws(lbl))) {
        stop(sprintf(
          "mr_envelopes(): envelope %d `.label` must be a non-empty string.", k
        ), call. = FALSE)
      }
    }
  }
  # Warn (not error) on duplicate .label — intentional reruns under the
  # same label are valid (seeded replays), but the relaunch path picks
  # "the most recent run with this label", so silent duplicates are a
  # frequent confusion.
  labels <- vapply(envelopes, function(e) {
    if (".label" %in% names(e)) as.character(e$.label) else NA_character_
  }, character(1))
  labeled <- labels[!is.na(labels)]
  dupes <- unique(labeled[duplicated(labeled)])
  if (length(dupes) > 0L) {
    warning(sprintf(
      "mr_envelopes(): duplicate .label across envelopes: %s. Relaunch by label resolves to the most recent run with that label.",
      paste(sprintf("'%s'", dupes), collapse = ", ")
    ), call. = FALSE)
  }
  structure(envelopes, class = "mr_binds", mode = "envelopes")
}
