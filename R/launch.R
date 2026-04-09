#' Launch an R script as a tracked modelrunnR step
#'
#' `launch()` is the tracked-execution entry point. It sources
#' `script_path` inside an instrumented context that watches for
#' `grab()` and `stow()` calls, measures wall-clock duration, and
#' writes a run record to `_mr_runs` whether the script succeeds
#' or errors.
#'
#' The script is sourced in a fresh environment whose parent is
#' `globalenv()`. `grab` and `stow` are injected directly into the
#' script's environment so scripts can call them bare without a
#' preceding `library(modelrunnR)`.
#'
#' @section Shadowed `source()`:
#' During a tracked launch, `source()` inside the script (and inside
#' any transitively-sourced helper) is shadowed with a wrapper that
#' records each sourced file's path + byte hash on the run row.
#'
#' The wrapper's default for `local` is `TRUE` (resolving to the
#' caller's frame), whereas `base::source()`'s default is `FALSE`
#' (which evaluates into `globalenv()`). Scripts that rely on
#' `source("helper.R")` populating `globalenv()` will instead find
#' their helpers scoped to the script's evaluation environment.
#' Explicitly passing `source("helper.R", local = FALSE)` still
#' works.
#'
#' @param script_path Path to the R script to run.
#' @param rebind Optional named list that overrides what each
#'   `grab()` inside the script resolves to. List values may be bare
#'   R objects (stowed inline through the normal versioning path) or
#'   reference constructors ([mr_hash()], [mr_run()], [mr_variant()],
#'   [mr_as_of()]) that resolve to existing versions without
#'   round-tripping through R memory.
#' @param external_inputs Optional named list with fields `files` (a
#'   character vector of paths) and/or `env` (a character vector of
#'   environment variable names). Each declared input is hashed and
#'   recorded on the run row so later staleness checks can detect
#'   changes. Missing files error *before* the script is sourced.
#' @param label Optional string marking this run as belonging to a tracked
#'   variant (labeled experimental thread). Empty / whitespace-only labels
#'   are rejected; whitespace is trimmed. See *Variants and swappability*
#'   in docs/design.md for the full semantics.
#' @param ... Reserved for future arguments and for catching the
#'   removed `pin`/`data` arguments with a clear error message.
#'
#' @return The run record (one row of `_mr_runs`), invisibly.
#' @export
launch <- function(script_path, rebind = NULL, label = NULL, external_inputs = NULL, ...) {
  dots <- list(...)
  if ("pin" %in% names(dots) || "data" %in% names(dots)) {
    stop(
      "launch(): `pin` and `data` were removed in the swappability rework. ",
      "Use `rebind = list(...)`: bare R values replace `data`, ",
      "and mr_hash()/mr_run() replace `pin`. See docs/design.md ",
      "section 'Variants and swappability'.",
      call. = FALSE
    )
  }
  if (length(dots) > 0) {
    stop(sprintf("launch(): unknown arguments: %s",
                 paste(names(dots), collapse = ", ")),
         call. = FALSE)
  }
  label <- .mr_validate_label(label)
  stopifnot(
    is.character(script_path),
    length(script_path) == 1L,
    nzchar(script_path)
  )
  if (!file.exists(script_path)) {
    stop(sprintf("launch(): script not found: %s", script_path), call. = FALSE)
  }

  # Normalize path so the `step` column is stable relative to resolution.
  step <- normalizePath(script_path, mustWork = TRUE)
  run_id     <- .mr_new_run_id()
  started_at <- Sys.time()
  start_secs <- as.numeric(started_at)

  # Ensure the connection + schema exist before we start timing user code.
  .mr_get_connection()

  # Resolve declared external inputs up-front so a missing file errors
  # before we write anything to _mr_runs.
  resolved_ext <- .mr_resolve_external_inputs(external_inputs)

  # Resolve rebind up-front. Bare R values are stowed (producing fresh
  # hashes); mr_*() references are resolved to existing content_hashes.
  resolved_rebinds <- .mr_resolve_rebinds(rebind)

  # Advisory staleness check -- report only, never auto-skip.
  # Pass the explicit label only (auto-propagation hasn't run yet, so
  # inherited labels aren't known here; passing label= ensures per-variant
  # history is consulted when the user supplied an explicit label).
  staleness <- .mr_is_stale(step, variant_label = label)
  .mr_print_staleness(step, staleness)

  # Nested launches would clobber the outer launch's recording, helpers,
  # and rebinds state (all held in .mr_state singletons). Detect and error
  # rather than silently corrupting the outer run. A push/pop stack is
  # post-v0.1.
  if (.mr_is_recording() || !is.null(.mr_state$helpers) || !is.null(.mr_state$rebinds)) {
    stop("launch(): nested launches are not supported in v0.1.", call. = FALSE)
  }

  .mr_start_recording()
  .mr_start_helper_tracking()
  .mr_start_rebinding(resolved_rebinds)
  on.exit(
    {
      if (.mr_is_recording()) .mr_stop_recording()
      if (!is.null(.mr_state$helpers)) .mr_stop_helper_tracking()
      .mr_stop_rebinding()
    },
    add = TRUE
  )

  status  <- "success"
  err_obj <- NULL
  tryCatch(
    .mr_source_script(step),
    error = function(e) {
      status  <<- "error"
      err_obj <<- e
    }
  )

  rec     <- .mr_stop_recording()
  helpers <- .mr_stop_helper_tracking()
  duration_ms <- as.integer(round((as.numeric(Sys.time()) - start_secs) * 1000))

  code_hash <- .mr_code_hash(step, helpers)

  # Surface inputs that trace back to interactive writes -- design's
  # "patched a table from the REPL and then a script depended on it"
  # land mine. Done before writing the run row so the warning never
  # looks at the current, in-progress run.
  .mr_warn_interactive_inputs(step, rec$inputs)

  # Auto-propagation: if the user didn't pass label= explicitly,
  # inspect the observed inputs for labeled upstreams and inherit if
  # all agree.
  propagation_source <- NULL
  if (is.na(label)) {
    con_for_prop <- .mr_get_connection()
    prop <- .mr_propagate_label(con_for_prop, rec$inputs)
    if (!is.na(prop)) {
      inherited_label <- unclass(prop)
      label <- inherited_label
      propagation_source <- .mr_first_input_producing(rec$inputs,
                                                       con_for_prop,
                                                       inherited_label)
    } else if (!is.null(attr(prop, "disagreement"))) {
      disagreement <- attr(prop, "disagreement")
      warning(sprintf(
        "ambiguous upstream variants: %s. Running without a label; pass label= to disambiguate.",
        paste(sprintf("%s -> %s", names(disagreement), unlist(disagreement)),
              collapse = ", ")
      ), call. = FALSE)
    }
  }

  run_row <- .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = rec$inputs,
    outputs         = rec$outputs,
    started_at      = started_at,
    duration_ms     = duration_ms,
    status          = status,
    code_hash       = code_hash,
    external_inputs = resolved_ext,
    helpers         = helpers,
    variant_label   = label
  )

  .mr_print_timing_summary(
    step,
    duration_ms,
    status,
    n_grabs            = rec$n_grabs,
    n_stows            = rec$n_stows,
    variant_label      = label,
    propagation_source = propagation_source
  )

  if (!is.null(err_obj)) {
    stop(err_obj)
  }

  invisible(run_row)
}

## Internals ------------------------------------------------------------------

.mr_new_run_id <- function() {
  ts  <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
  suf <- paste(sample(c(0:9, letters[1:6]), 6, replace = TRUE), collapse = "")
  sprintf("run_%s_%s", gsub("[^0-9A-Za-z_]", "", ts), suf)
}

.mr_source_script <- function(path) {
  envir <- new.env(parent = globalenv())
  # Inject grab/stow so scripts can call them without library(modelrunnR),
  # and shadow `source` with the helper-tracking wrapper so every helper
  # the script (or a transitively-sourced helper) loads is recorded.
  envir$grab   <- grab
  envir$stow   <- stow
  envir$source <- .mr_make_source_wrapper()
  base::source(path, local = envir, echo = FALSE, keep.source = FALSE)
  invisible(NULL)
}

.mr_write_run_row <- function(step, run_id, inputs, outputs,
                              started_at, duration_ms, status,
                              code_hash = NA_character_,
                              external_inputs = list(files = list(), env = list()),
                              helpers = list(),
                              variant_label = NA_character_) {
  con <- .mr_get_connection()
  row <- data.frame(
    step            = step,
    run_id          = run_id,
    inputs          = .mr_pairs_to_json(inputs),
    outputs         = .mr_pairs_to_json(outputs),
    started_at      = started_at,
    duration_ms     = duration_ms,
    status          = status,
    code_hash       = code_hash,
    external_inputs = .mr_external_inputs_to_json(external_inputs),
    helpers         = .mr_helpers_to_json(helpers),
    variant_label   = variant_label,
    stringsAsFactors = FALSE
  )
  DBI::dbAppendTable(con, "_mr_runs", row)
  row
}

.mr_helpers_to_json <- function(helpers) {
  if (length(helpers) == 0L) return("[]")
  entries <- lapply(names(helpers), function(p) list(path = p, hash = helpers[[p]]))
  jsonlite::toJSON(entries, auto_unbox = TRUE)
}

# Serialize a list of list(name, hash) pairs to a JSON array of objects.
# `auto_unbox = TRUE` keeps scalar fields from getting wrapped in
# one-element arrays, which would make downstream parsers uglier.
.mr_pairs_to_json <- function(pairs) {
  if (length(pairs) == 0L) return("[]")
  jsonlite::toJSON(pairs, auto_unbox = TRUE)
}

.mr_print_timing_summary <- function(step, duration_ms, status,
                                     n_grabs = 0L, n_stows = 0L,
                                     variant_label = NA_character_,
                                     propagation_source = NULL) {
  lines <- sprintf(
    "modelrunnR: %s [%s] in %s ms (%d grabs, %d stows)",
    basename(step), status, format(duration_ms, big.mark = ","),
    n_grabs, n_stows
  )
  if (!is.na(variant_label)) {
    if (!is.null(propagation_source) && !is.na(propagation_source)) {
      lines <- c(lines, sprintf("  variant: %s (inherited from %s)",
                                variant_label, propagation_source))
    } else {
      lines <- c(lines, sprintf("  variant: %s", variant_label))
    }
  }
  message(paste(lines, collapse = "\n"))
}

.mr_print_staleness <- function(step, staleness) {
  if (!staleness$stale) {
    message(sprintf("modelrunnR: %s is fresh", basename(step)))
    return(invisible(NULL))
  }
  message(sprintf(
    "modelrunnR: %s is stale (reasons: %s)",
    basename(step),
    paste(staleness$reasons, collapse = ", ")
  ))
  invisible(NULL)
}
