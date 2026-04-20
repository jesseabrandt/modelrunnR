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
#' @param script_path Either a path to an R script (script mode) or a
#'   braced expression block `{ ... }` (inline mode). Dispatch is by
#'   syntax: a literal `{ ... }` in the call triggers inline mode;
#'   anything else is resolved as a path.
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
#' @param ... Reserved for future arguments and for catching the
#'   removed `pin`/`data` arguments with a clear error message.
#'
#' @return The run record (one row of `_mr_runs`), invisibly.
#' @export
launch <- function(script_path, rebind = NULL, label = NULL, external_inputs = NULL,
                   force = FALSE, duckdb_seed = NULL, materialize = FALSE, ...) {
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
  if (!is.logical(materialize) || length(materialize) != 1L || is.na(materialize)) {
    stop("launch(): `materialize` must be TRUE or FALSE.", call. = FALSE)
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

  # Dispatch: a literal `{ ... }` block triggers inline mode. Capturing
  # with substitute() before `script_path` is ever touched is load-bearing
  # -- forcing the promise would evaluate user code outside our tracking.
  script_expr <- substitute(script_path)
  inline_mode <- is.call(script_expr) && identical(script_expr[[1]], as.name("{"))

  # SQL dispatch: handled before the R-mode dispatch ladder. Two routes:
  #   - inline  : first arg is mr_sql("...")
  #   - file    : first arg is a path with `.sql` extension (case-
  #               insensitive)
  # `materialize` only applies here; non-SQL launches that pass it
  # silently ignore (spec keeps the signature clean).
  is_inline_sql <- !inline_mode && inherits(script_path, "mr_ref_sql")
  is_file_sql <- FALSE
  if (!inline_mode && !is_inline_sql && is.character(script_path) &&
      length(script_path) == 1L && !is.na(script_path) && nzchar(script_path)) {
    ext <- tolower(tools::file_ext(script_path))
    if (ext == "sql") is_file_sql <- TRUE
  }
  if (is_inline_sql || is_file_sql) {
    src_kind     <- if (is_inline_sql) "inline" else "file"
    body_or_path <- if (is_inline_sql) script_path$body else script_path
    resolved_ext       <- .mr_resolve_external_inputs(external_inputs)
    resolved_rebinds   <- .mr_resolve_rebinds(rebind)
    skip_on_fresh      <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))
    # Nested-launch guard mirrors the R-mode rule: a SQL launch that
    # would run from inside an active R-mode recording would clobber
    # the outer's state on the recording side and confuse provenance.
    if (.mr_is_recording() || !is.null(.mr_state$helpers) ||
        !is.null(.mr_state$rebinds)) {
      stop("launch(): nested launches are not supported in v0.1.", call. = FALSE)
    }
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

  if (!inline_mode && .mr_is_ref(script_path)) {
    if (!identical(script_path$kind, "label")) {
      stop(sprintf(
        "launch(): only mr_label() is accepted as a first argument reference; got mr_%s().",
        script_path$kind
      ), call. = FALSE)
    }
    relaunch_mode <- TRUE
  }

  if (inline_mode) {
    code_body <- paste(deparse(script_expr, width.cutoff = 500L), collapse = "\n")
    expr_hash <- .mr_hash_bytes(charToRaw(code_body))
    # Step identifier is derived from the expression hash so editing the
    # block yields a new logical step rather than a false "stale" report
    # against an older expression's history.
    step <- sprintf("<inline:%s>", substr(expr_hash, 1L, 12L))
  } else if (relaunch_mode) {
    resolved <- .mr_resolve_relaunch(script_path$value)
    step          <- resolved$step
    code_body     <- resolved$code_body
    relaunch_expr <- resolved$expr
    # Auto-inherit the label unless the user passed one explicitly.
    if (is.na(label)) label <- script_path$value
  } else {
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
    # Capture the file bytes as the run's recovery snapshot. Later the
    # file may be edited or deleted; this keeps the run row self-contained.
    code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
  }

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
  # Resolution returns a name->hash `map` for grab() to read, plus a
  # `provenance` list (one entry per rebound name) recorded on the run
  # row so a query against `_mr_runs` can answer "what did this run
  # bind to?" without joining back through `_mr_versions`.
  resolved_rebinds <- .mr_resolve_rebinds(rebind)
  rebinds_map        <- resolved_rebinds$map
  rebinds_provenance <- resolved_rebinds$provenance

  # Seed DuckDB's RNG if requested. Must happen before the block
  # evaluates so any slice_sample / RANDOM() inside uses this seed.
  # DuckDB's RNG is connection-scoped and we do not restore it after
  # the block -- documented limitation.
  if (!is.null(duckdb_seed)) {
    con_for_seed <- .mr_get_connection()
    DBI::dbExecute(con_for_seed, "SELECT setseed(?)", params = list(duckdb_seed))
  }

  # Staleness check. Default behavior (v0.2+) is skip-on-fresh:
  # when a step is fresh under the current label, the block is not
  # evaluated and a `skipped_fresh` run row is written. `force = TRUE`
  # on the call and `options(modelrunnR.skip_if_fresh = FALSE)` both
  # opt out. We pass the explicit label only -- auto-propagation runs
  # from the recorded inputs of the finished block, which hasn't run
  # yet.
  staleness <- .mr_is_stale(step, variant_label = label)
  skip_on_fresh <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))
  will_skip <- !staleness$stale && !isTRUE(force) && skip_on_fresh
  .mr_print_staleness(step, staleness, will_skip = will_skip)

  if (will_skip) {
    return(invisible(.mr_record_skipped_fresh(
      step            = step,
      run_id          = run_id,
      started_at      = started_at,
      resolved_ext    = resolved_ext,
      code_body       = code_body,
      label           = label,
      rebinds         = rebinds_provenance,
      duckdb_seed     = duckdb_seed
    )))
  }

  # Nested launches would clobber the outer launch's recording, helpers,
  # and rebinds state (all held in .mr_state singletons). Detect and error
  # rather than silently corrupting the outer run. A push/pop stack is
  # post-v0.1.
  if (.mr_is_recording() || !is.null(.mr_state$helpers) || !is.null(.mr_state$rebinds)) {
    stop("launch(): nested launches are not supported in v0.1.", call. = FALSE)
  }

  .mr_start_recording()
  .mr_start_helper_tracking()
  .mr_start_rebinding(rebinds_map)
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
    if (inline_mode) {
      .mr_eval_inline(script_expr)
    } else if (relaunch_mode && !is.null(relaunch_expr)) {
      .mr_eval_inline(relaunch_expr)
    } else {
      .mr_source_script(step)
    },
    error = function(e) {
      status  <<- "error"
      err_obj <<- e
    }
  )

  rec     <- .mr_stop_recording()
  helpers <- .mr_stop_helper_tracking()
  duration_ms <- as.integer(round((as.numeric(Sys.time()) - start_secs) * 1000))

  code_hash <- if (inline_mode || (relaunch_mode && !is.null(relaunch_expr))) {
    # Inline execution (by construction: either a braced block or a
    # relaunch that falls back to the stored snapshot).
    .mr_code_hash_inline(code_body, helpers)
  } else {
    .mr_code_hash(step, helpers)
  }

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
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = rebinds_provenance
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
                              rebinds = list()) {
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
    code_body       = code_body,
    duckdb_seed     = duckdb_seed,
    rebinds         = .mr_pairs_to_json(rebinds),
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
# stays in the same labeled thread.
.mr_record_skipped_fresh <- function(step, run_id, started_at,
                                     resolved_ext, code_body, label,
                                     rebinds = list(),
                                     duckdb_seed = NULL) {
  con <- .mr_get_connection()
  if (is.na(label)) {
    prior <- DBI::dbGetQuery(
      con,
      "SELECT variant_label, code_hash FROM _mr_runs
        WHERE step = ?
        ORDER BY started_at DESC LIMIT 1",
      params = list(step)
    )
    if (nrow(prior) > 0L && !is.na(prior$variant_label[1])) {
      label <- prior$variant_label[1]
    }
  }
  prior_hash <- DBI::dbGetQuery(
    con,
    "SELECT code_hash FROM _mr_runs
      WHERE step = ?
      ORDER BY started_at DESC LIMIT 1",
    params = list(step)
  )
  code_hash <- if (nrow(prior_hash) == 0L) NA_character_ else prior_hash$code_hash[1]

  .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = list(),
    outputs         = list(),
    started_at      = started_at,
    duration_ms     = 0L,
    status          = "skipped_fresh",
    code_hash       = code_hash,
    external_inputs = resolved_ext,
    helpers         = list(),
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = rebinds
  )
}
