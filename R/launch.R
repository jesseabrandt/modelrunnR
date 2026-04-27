#' Launch a tracked modelrunnR step
#'
#' `launch()` is the tracked-execution entry point. It runs user code
#' inside an instrumented context that watches for `grab()` and
#' `stow()` calls, measures wall-clock duration, and writes a run
#' record to `_mr_runs` whether the code succeeds or errors.
#'
#' The code runs in a fresh environment whose parent is `globalenv()`.
#' `grab` and `stow` are injected directly into that environment so
#' the tracked code can call them bare without a preceding
#' `library(modelrunnR)`.
#'
#' @section Script, inline, and relaunch modes:
#' `launch()` dispatches on the first argument:
#' - **Script mode** -- `launch("fit.R")` sources a file.
#' - **Inline mode** -- `launch({ ... })` evaluates a braced block as
#'   tracked code, with no script file on disk. Useful for vignettes,
#'   quick experiments, and one-off tracked runs. The step identifier
#'   is derived from the deparsed expression's hash
#'   (`"<inline:<short-hash>>"`), so editing the expression produces a
#'   new tracked step rather than silently comparing against a prior
#'   run's history.
#' - **Relaunch mode** -- `launch(mr_label("baseline"))` looks up the
#'   most recent run tagged with that label and re-executes its code.
#'   For inline pipelines the stored snapshot on the run row is used
#'   directly. For file pipelines the script file is re-sourced from
#'   disk; if the file is gone, the stored snapshot is used and an
#'   informational message is emitted. The label is auto-inherited
#'   onto the new run unless the caller passes an explicit `label`.
#' - **SQL mode** -- `launch("features.sql")` (file) or
#'   `launch(mr_sql("..."))` (inline) registers a SQL `SELECT` as a
#'   tracked step. The body is a bare query (no `CREATE`); modelrunnR
#'   wraps it as `CREATE OR REPLACE VIEW <physical> AS <body>` by
#'   default, or `CREATE OR REPLACE TABLE` when `materialize = TRUE`.
#'   `-- @inputs: name1, name2` and `-- @output: name` headers declare
#'   which modelrunnR-managed names the SELECT references and what to
#'   call the result. See [mr_sql()] for the inline form.
#'
#' @section Shadowed `source()`:
#' During a tracked launch, `source()` inside the code (and inside
#' any transitively-sourced helper) is shadowed with a wrapper that
#' records each sourced file's path + byte hash on the run row.
#'
#' The wrapper's default for `local` is `TRUE` (resolving to the
#' caller's frame), whereas `base::source()`'s default is `FALSE`
#' (which evaluates into `globalenv()`). Scripts that rely on
#' `source("helper.R")` populating `globalenv()` will instead find
#' their helpers scoped to the tracked environment. Explicitly
#' passing `source("helper.R", local = FALSE)` still works.
#'
#' @param code The code modelrunnR should run. One of:
#'   - a braced `{ ... }` block (inline R) -- a literal `{ ... }` at
#'     the call site triggers inline mode.
#'   - a path to an `.R` script (R file mode).
#'   - a path to a `.sql` file, or [mr_sql()] (SQL mode).
#'   - [mr_label()] (relaunch mode -- re-executes the most recent run
#'     under that label).
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
#' @param force Logical, default `FALSE`. When `FALSE` and the step is
#'   fresh (code + inputs + external inputs unchanged since the last run
#'   under this label), `launch()` skips execution entirely: the block is
#'   not evaluated, side effects do not fire, and a `_mr_runs` row is
#'   written with `status = "skipped_fresh"` to preserve provenance.
#'   `force = TRUE` runs the block regardless. To globally disable
#'   skip-on-fresh behavior (restore pre-v0.1 advisory-only staleness),
#'   set `options(modelrunnR.skip_if_fresh = FALSE)`.
#' @section Batch launches:
#' Pass `rebind = mr_binds(...)` (or `mr_envelopes(...)`) to fan out
#' into one launch per envelope. The block runs once per envelope with
#' that envelope's rebind / `.label`; the call returns a `data.frame`
#' of one run row per envelope (same shape as the single-launch
#' return). Errors in any envelope are captured on that envelope's
#' `_mr_runs` row (`status = "error"`) and the call raises (or warns
#' if `on_error = "warn"`) at the end with a count summary. Works for
#' both R-mode and SQL-mode launches.
#'
#' @param materialize Logical, default `FALSE`. SQL launches only.
#'   When `TRUE`, the SELECT body is wrapped as `CREATE OR REPLACE
#'   TABLE` instead of the default `CREATE OR REPLACE VIEW`, and the
#'   `_mr_versions` row's `content_hash` is computed over row contents
#'   (same machinery as `stow()`-of-lazy-tbl). Use for expensive
#'   feature work consumed many times downstream. Ignored for non-SQL
#'   launches.
#' @param duckdb_seed Optional numeric seed in `[-1, 1]`. When set,
#'   modelrunnR calls `SELECT setseed(duckdb_seed)` on the DuckDB
#'   connection immediately before evaluating the block, so lazy-tbl
#'   samplers (`dplyr::slice_sample()`, `RANDOM()`, `USING SAMPLE`)
#'   produce reproducible output across runs with the same seed. The
#'   value is stored on the run row. Note: this is DuckDB's RNG, not
#'   R's -- `set.seed()` does not reach DuckDB. The RNG state is not
#'   restored after the block.
#' @param on_error `"raise"` (default) or `"warn"`. Batch mode only.
#'   Controls whether the final call raises or warns when one or more
#'   envelopes errored. Per-envelope rows are captured on `_mr_runs`
#'   either way. Passing this argument outside batch mode is an error.
#' @param ... Reserved for future arguments. Also traps legacy
#'   arguments: `pin` / `data` from before the swappability rework
#'   (error), and the deprecated `script_path` alias for `code`
#'   (deprecation warning).
#'
#' @return The run record (one row of `_mr_runs`), invisibly.
#' @export
launch <- function(code, rebind = NULL, label = NULL, external_inputs = NULL,
                   force = FALSE, duckdb_seed = NULL, materialize = FALSE,
                   on_error = "raise", ...) {
  dots <- list(...)

  # Deprecation shim for the old `script_path = ` name. See the dispatch
  # block below for why the capture must happen here.
  if ("script_path" %in% names(dots)) {
    if (!missing(code)) {
      stop(
        "launch(): `script_path` is deprecated; pass `code` only (not both).",
        call. = FALSE
      )
    }
    warning(
      "launch(): `script_path` is deprecated; use `code` instead. ",
      "The argument accepts a braced block, a file path, mr_label(), or ",
      "mr_sql() -- not only a script path.",
      call. = FALSE
    )
    mcall <- match.call()
    script_expr <- mcall[["script_path"]]
    code <- dots$script_path
    dots[names(dots) == "script_path"] <- NULL
  } else {
    script_expr <- substitute(code)
  }

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
  if (!is.logical(materialize) || length(materialize) != 1L || is.na(materialize)) {
    stop("launch(): `materialize` must be TRUE or FALSE.", call. = FALSE)
  }
  if (!is.character(on_error) || length(on_error) != 1L ||
      !(on_error %in% c("raise", "warn"))) {
    stop("launch(): `on_error` must be \"raise\" or \"warn\".", call. = FALSE)
  }
  if (!inherits(rebind, "mr_binds") && !identical(on_error, "raise")) {
    stop(
      "launch(): on_error only applies when rebind = is an mr_binds() / mr_envelopes() object.",
      call. = FALSE
    )
  }
  label <- .mr_validate_label(label)

  if (!is.null(duckdb_seed)) {
    if (!is.numeric(duckdb_seed) || length(duckdb_seed) != 1L || is.na(duckdb_seed)) {
      stop("launch(): duckdb_seed must be a single numeric value.", call. = FALSE)
    }
    if (duckdb_seed < -1 || duckdb_seed > 1) {
      stop(sprintf(
        "launch(): duckdb_seed must be in [-1, 1]; got %s.", duckdb_seed
      ), call. = FALSE)
    }
  }

  # Dispatch: a literal `{ ... }` block triggers inline mode. `script_expr`
  # was captured at the top of the body (from `substitute(code)` or from
  # the deprecation shim's match.call(), so the braced block form works
  # under both argument names).
  inline_mode <- is.call(script_expr) && identical(script_expr[[1]], as.name("{"))

  # SQL dispatch: handled before the R-mode dispatch ladder. Two routes:
  #   - inline  : first arg is mr_sql("...")
  #   - file    : first arg is a path with `.sql` extension (case-
  #               insensitive)
  # `materialize` only applies here; non-SQL launches that pass it
  # silently ignore (spec keeps the signature clean).
  is_inline_sql <- !inline_mode && inherits(code, "mr_ref_sql")
  is_file_sql <- FALSE
  if (!inline_mode && !is_inline_sql && is.character(code) &&
      length(code) == 1L && !is.na(code) && nzchar(code)) {
    ext <- tolower(tools::file_ext(code))
    if (ext == "sql") is_file_sql <- TRUE
  }
  if (is_inline_sql || is_file_sql) {
    src_kind     <- if (is_inline_sql) "inline" else "file"
    body_or_path <- if (is_inline_sql) code$body else code

    # Batch: one .mr_launch_sql() call per envelope. step/code_body
    # depend only on src_kind+body, not rebind, so they're resolved
    # once inside the SQL launcher per envelope (cheap; no I/O for
    # inline; one read for file).
    if (inherits(rebind, "mr_binds")) {
      return(.mr_launch_batch_sql(
        src_kind        = src_kind,
        body_or_path    = body_or_path,
        envelopes       = unclass(rebind),
        materialize     = materialize,
        label           = label,
        external_inputs = external_inputs,
        force           = force,
        duckdb_seed     = duckdb_seed,
        on_error        = on_error
      ))
    }

    resolved_ext       <- .mr_resolve_external_inputs(external_inputs)
    resolved_rebinds   <- .mr_resolve_rebinds(rebind)
    .mr_state$pending_shape_b_filters <- NULL   # SQL path: no R grab(); discard
    skip_on_fresh      <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))
    # Nested-launch guard mirrors the R-mode rule: a SQL launch that
    # would run from inside an active R-mode recording would clobber
    # the outer's state on the recording side and confuse provenance.
    .mr_guard_no_nested_launch()
    return(.mr_launch_sql(
      src_kind                = src_kind,
      path_or_body            = body_or_path,
      materialize             = materialize,
      rebind                  = resolved_rebinds$map,
      provenance              = resolved_rebinds$provenance,
      external_inputs_resolved = resolved_ext,
      label                   = label,
      force                   = force,
      duckdb_seed             = duckdb_seed,
      skip_on_fresh           = skip_on_fresh
    ))
  }

  relaunch_mode <- FALSE
  relaunch_expr <- NULL  # parsed code body for relaunch execution
  relaunch_kind <- NULL  # "label" or "run" when relaunch_mode is TRUE

  if (!inline_mode && .mr_is_ref(code)) {
    if (!(code$kind %in% c("label", "run"))) {
      stop(sprintf(
        "launch(): only mr_label() and mr_run() are accepted as first argument references; got mr_%s().",
        code$kind
      ), call. = FALSE)
    }
    relaunch_mode <- TRUE
    relaunch_kind <- code$kind
  }

  if (inline_mode) {
    code_body <- paste(deparse(script_expr, width.cutoff = 500L), collapse = "\n")
    expr_hash <- .mr_hash_bytes(charToRaw(code_body))
    # Step identifier is derived from the expression hash so editing the
    # block yields a new logical step rather than a false "stale" report
    # against an older expression's history.
    step <- sprintf("<inline:%s>", substr(expr_hash, 1L, 12L))
  } else if (relaunch_mode) {
    resolved <- if (identical(relaunch_kind, "label")) {
      .mr_resolve_relaunch(code$value)
    } else {
      .mr_resolve_relaunch_run_id(code$value)
    }
    step          <- resolved$step
    code_body     <- resolved$code_body
    relaunch_expr <- resolved$expr
    # Auto-inherit label. For mr_label() the label is the ref's value.
    # For mr_run() it's the source row's variant_label (may be NA).
    if (is.na(label)) {
      label <- if (identical(relaunch_kind, "label")) {
        code$value
      } else {
        resolved$variant_label
      }
    }

    # Non-success source: warn / error / silent per option. Only
    # applies to mr_run() — mr_label() resolves by latest, which by
    # construction usually points at a success row. "queued" is a
    # normal pre-execution state (Task P2.10), not a failure — skip.
    if (identical(relaunch_kind, "run") &&
        !is.na(resolved$status) &&
        !identical(resolved$status, "success") &&
        !identical(resolved$status, "queued")) {
      policy <- match.arg(
        getOption("modelrunnR.relaunch_nonsuccess", "warn"),
        c("warn", "error", "silent")
      )
      msg <- sprintf(
        "launch(): re-executing run_id '%s' whose source row has status '%s'.",
        code$value, resolved$status
      )
      if (identical(policy, "error")) {
        stop(paste(msg, "Set options(modelrunnR.relaunch_nonsuccess = \"warn\") to relaunch anyway."),
             call. = FALSE)
      }
      if (identical(policy, "warn")) warning(msg, call. = FALSE)
    }
  } else {
    stopifnot(
      is.character(code),
      length(code) == 1L,
      nzchar(code)
    )
    if (!file.exists(code)) {
      stop(sprintf("launch(): file not found: %s", code), call. = FALSE)
    }
    # Normalize path so the `step` column is stable relative to resolution.
    step <- normalizePath(code, mustWork = TRUE)
    # Capture the file bytes as the run's recovery snapshot. Later the
    # file may be edited or deleted; this keeps the run row self-contained.
    code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
  }

  # R-mode batch: dispatch once per envelope, sharing the resolved
  # step / code_body / inline_mode / relaunch_expr (none of which
  # depend on rebind). Each envelope contributes its own rebind list
  # and optional `.label`.
  if (inherits(rebind, "mr_binds")) {
    return(.mr_launch_batch(
      step            = step,
      code_body       = code_body,
      inline_mode     = inline_mode,
      relaunch_mode   = relaunch_mode,
      relaunch_expr   = relaunch_expr,
      script_expr     = script_expr,
      envelopes       = unclass(rebind),
      label           = label,
      external_inputs = external_inputs,
      force           = force,
      duckdb_seed     = duckdb_seed,
      on_error        = on_error
    ))
  }

  .mr_launch_one(
    step            = step,
    code_body       = code_body,
    inline_mode     = inline_mode,
    relaunch_mode   = relaunch_mode,
    relaunch_expr   = relaunch_expr,
    script_expr     = script_expr,
    rebind          = rebind,
    label           = label,
    external_inputs = external_inputs,
    force           = force,
    duckdb_seed     = duckdb_seed
  )
}

## Internals ------------------------------------------------------------------

# Raise if a launch is fired while another launch is already active
# (recording, helper-tracking, or rebinding). Called from both R-mode
# and SQL-mode, single and batch dispatchers.
.mr_guard_no_nested_launch <- function() {
  if (.mr_is_recording() || !is.null(.mr_state$helpers) ||
      !is.null(.mr_state$rebinds)) {
    stop("launch(): nested launches are not supported in v0.1.", call. = FALSE)
  }
  invisible(NULL)
}

.mr_new_id <- function(prefix) {
  ts  <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
  suf <- paste(sample(c(0:9, letters[1:6]), 6, replace = TRUE), collapse = "")
  sprintf("%s_%s_%s", prefix, gsub("[^0-9A-Za-z_]", "", ts), suf)
}

.mr_new_run_id   <- function() .mr_new_id("run")
.mr_new_batch_id <- function() .mr_new_id("batch")

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

# Resolve a relaunch-by-label reference to (step, code_body, expr).
#
# - step: the original pipeline's step (file path or <inline:...>).
# - code_body: the source to attribute to the new run row.
# - expr: a parsed expression when we want to eval a stored snapshot,
#   NULL when the caller should source step from disk.
#
# Rules: inline-step pipelines always execute the stored snapshot.
# File-step pipelines re-source the file when it exists; when the
# file is gone we fall back to the stored snapshot and emit an
# informational message, matching launch_code()'s behavior.
.mr_resolve_relaunch <- function(label) {
  con <- .mr_get_connection()
  prior <- DBI::dbGetQuery(
    con,
    "SELECT step, code_body FROM _mr_runs
      WHERE variant_label = ?
      ORDER BY started_at DESC LIMIT 1",
    params = list(label)
  )
  if (nrow(prior) == 0L) {
    stop(sprintf(
      "launch(): no run with label '%s'. Label a pipeline first via launch(..., label = \"%s\").",
      label, label
    ), call. = FALSE)
  }
  step        <- prior$step[1]
  stored_body <- prior$code_body[1]

  if (startsWith(step, "<inline:")) {
    if (is.na(stored_body) || !nzchar(stored_body)) {
      stop(sprintf(
        "launch(): label '%s' resolves to an inline run with no stored code body.",
        label
      ), call. = FALSE)
    }
    return(list(step = step, code_body = stored_body,
                expr = parse(text = stored_body)))
  }

  # File-step pipeline.
  if (file.exists(step)) {
    file_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
    return(list(step = step, code_body = file_body, expr = NULL))
  }
  if (!is.na(stored_body) && nzchar(stored_body)) {
    message(sprintf(
      "launch(): script '%s' is gone from disk; running the stored snapshot from label '%s'.",
      step, label
    ))
    return(list(step = step, code_body = stored_body,
                expr = parse(text = stored_body)))
  }
  stop(sprintf(
    "launch(): script '%s' is gone and no snapshot is stored for label '%s'.",
    step, label
  ), call. = FALSE)
}

# Resolve a run by run_id for relaunch. Mirrors .mr_resolve_relaunch()
# (label-based) but keys on run_id. See spec
# docs/superpowers/specs/2026-04-26-launch-by-run-id-design.md.
#
# Returns a richer list than its sibling — adds `variant_label` and
# `status`. Both are needed by launch()'s mr_run() dispatch (label
# auto-inheritance from the source row; warn-on-non-success policy).
.mr_resolve_relaunch_run_id <- function(run_id) {
  con <- .mr_get_connection()
  prior <- DBI::dbGetQuery(
    con,
    "SELECT step, code_body, variant_label, status FROM _mr_runs
      WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(prior) == 0L) {
    stop(sprintf("launch(): no run with run_id '%s'.", run_id), call. = FALSE)
  }
  step        <- prior$step[1]
  stored_body <- prior$code_body[1]
  status      <- prior$status[1]
  variant     <- prior$variant_label[1]

  # Synthetic non-launch steps (e.g. "<interactive:...>"). Mirrors the
  # rule .mr_resolve_relaunch_code() applies for inline tags.
  if (startsWith(step, "<") && !startsWith(step, "<inline:")) {
    stop(sprintf(
      "launch(): run_id '%s' refers to a synthetic step ('%s') that isn't relaunchable.",
      run_id, step
    ), call. = FALSE)
  }

  if (startsWith(step, "<inline:")) {
    if (is.na(stored_body) || !nzchar(stored_body)) {
      stop(sprintf(
        "launch(): run_id '%s' is an inline run with no stored code body.",
        run_id
      ), call. = FALSE)
    }
    return(list(step = step, code_body = stored_body,
                expr = parse(text = stored_body),
                variant_label = variant, status = status))
  }

  if (file.exists(step)) {
    file_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
    return(list(step = step, code_body = file_body, expr = NULL,
                variant_label = variant, status = status))
  }
  if (!is.na(stored_body) && nzchar(stored_body)) {
    message(sprintf(
      "launch(): script '%s' is gone from disk; running the stored snapshot from run_id '%s'.",
      step, run_id
    ))
    return(list(step = step, code_body = stored_body,
                expr = parse(text = stored_body),
                variant_label = variant, status = status))
  }
  stop(sprintf(
    "launch(): script '%s' is gone and no snapshot is stored for run_id '%s'.",
    step, run_id
  ), call. = FALSE)
}

.mr_eval_inline <- function(expr) {
  envir <- new.env(parent = globalenv())
  envir$grab   <- grab
  envir$stow   <- stow
  envir$source <- .mr_make_source_wrapper()
  base::eval(expr, envir = envir)
  invisible(NULL)
}

.mr_write_run_row <- function(step, run_id, inputs, outputs,
                              started_at, duration_ms, status,
                              code_hash = NA_character_,
                              external_inputs = list(files = list(), env = list()),
                              helpers = list(),
                              variant_label = NA_character_,
                              code_body = NA_character_,
                              duckdb_seed = NA_real_,
                              rebinds = list(),
                              batch_id = NA_character_,
                              session_info = NULL) {
  con <- .mr_get_connection()
  # NULL means "capture now". Callers who want at-launch-start free RAM
  # capture explicitly and thread the list in; skipped/interactive paths
  # let the default fire.
  if (is.null(session_info)) session_info <- .mr_capture_session_info()
  row <- data.frame(
    step              = step,
    run_id            = run_id,
    inputs            = .mr_pairs_to_json(inputs),
    outputs           = .mr_pairs_to_json(outputs),
    started_at        = started_at,
    duration_ms       = duration_ms,
    status            = status,
    code_hash         = code_hash,
    external_inputs   = .mr_external_inputs_to_json(external_inputs),
    helpers           = .mr_helpers_to_json(helpers),
    variant_label     = variant_label,
    code_body         = code_body,
    duckdb_seed       = duckdb_seed,
    rebinds           = .mr_pairs_to_json(rebinds),
    batch_id          = batch_id,
    hostname          = session_info$hostname,
    os                = session_info$os,
    arch              = session_info$arch,
    r_version         = session_info$r_version,
    n_cpu             = session_info$n_cpu,
    total_ram_bytes   = session_info$total_ram_bytes,
    free_ram_bytes    = session_info$free_ram_bytes,
    attached_packages = session_info$attached_packages,
    git_sha           = session_info$git_sha,
    git_branch        = session_info$git_branch,
    git_dirty         = session_info$git_dirty,
    stringsAsFactors  = FALSE
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

.mr_print_staleness <- function(step, staleness, will_skip = FALSE) {
  if (!staleness$stale) {
    if (will_skip) {
      message(sprintf(
        "modelrunnR: %s is fresh -- skipping (use force = TRUE to run anyway)",
        basename(step)
      ))
    } else {
      message(sprintf("modelrunnR: %s is fresh", basename(step)))
    }
    return(invisible(NULL))
  }
  message(sprintf(
    "modelrunnR: %s is stale (reasons: %s)",
    basename(step),
    paste(staleness$reasons, collapse = ", ")
  ))
  invisible(NULL)
}

# Write a run row for a launch() that was skipped because the step was
# fresh. No user code ran, so `inputs`/`outputs` are empty and
# `duration_ms = 0`. `variant_label` inherits from the prior run's row
# for this step when the caller didn't pass one, so the skipped row
# stays in the same labeled thread. Shared by R-mode and SQL-mode
# launchers; they differ only in caller-side argument naming.
.mr_record_skipped_fresh <- function(step, run_id, started_at,
                                     external_inputs, code_body, label,
                                     rebinds = list(),
                                     duckdb_seed = NULL,
                                     batch_id = NA_character_,
                                     session_info = NULL) {
  con <- .mr_get_connection()
  prior <- DBI::dbGetQuery(
    con,
    "SELECT variant_label, code_hash FROM _mr_runs
      WHERE step = ?
      ORDER BY started_at DESC LIMIT 1",
    params = list(step)
  )
  if (is.na(label) && nrow(prior) > 0L && !is.na(prior$variant_label[1])) {
    label <- prior$variant_label[1]
  }
  code_hash <- if (nrow(prior) == 0L) NA_character_ else prior$code_hash[1]

  .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = list(),
    outputs         = list(),
    started_at      = started_at,
    duration_ms     = 0L,
    status          = "skipped_fresh",
    code_hash       = code_hash,
    external_inputs = external_inputs,
    helpers         = list(),
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = rebinds,
    batch_id        = batch_id,
    session_info    = session_info
  )
}
