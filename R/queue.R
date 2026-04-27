#' Stage a tracked run without executing it
#'
#' `queue()` registers a run row to `_mr_runs` with `status = "queued"`
#' but does not run the code. The queued row carries everything needed
#' to execute later: `step`, `code_body`, `code_hash`, `rebinds`,
#' `variant_label`, and `batch_id`. Pickup is the existing [launch()]
#' verb called with [mr_run()]:
#'
#' ```r
#' q <- queue({ fit_model(grab("x")) |> stow("model") })
#' launch(mr_run(q$run_id))   # picks up and executes; row updates in place
#' ```
#'
#' Parallel execution is not built in. Compose with `future`/`furrr`,
#' base R loops, or shell-level job runners (e.g. `tsp`, an HPC submit
#' script). modelrunnR records; the consumer executes.
#'
#' @param code A braced `{ ... }` block (inline) or a path to an
#'   `.R` script (file step). Reference objects ([mr_run()],
#'   [mr_label()], [mr_hash()]) and `.sql` paths / [mr_sql()] are
#'   rejected — re-queueing or staging SQL is out of scope.
#' @param rebind Optional named list, or [mr_binds()] / [mr_envelopes()]
#'   for batch staging (writes N queued rows under one `batch_id`).
#'   Same semantics as `launch(rebind = ...)`.
#' @param label Optional `variant_label` for the queued run.
#' @param duckdb_seed Optional numeric seed in `[-1, 1]`, recorded on
#'   the queued row and applied at pickup time.
#' @param ... Reserved for future arguments.
#'
#' @return The queued run record (one row of `_mr_runs`, or N rows for
#'   a batch) with `status = "queued"`, invisibly.
#' @export
queue <- function(code, rebind = NULL, label = NULL,
                  duckdb_seed = NULL, ...) {
  dots <- list(...)
  if (length(dots) > 0L) {
    stop(sprintf("queue(): unknown arguments: %s",
                 paste(names(dots), collapse = ", ")),
         call. = FALSE)
  }
  script_expr <- substitute(code)
  inline_mode <- is.call(script_expr) && identical(script_expr[[1]], as.name("{"))

  # Reject mr_sql() — SQL staging is out of scope (v1). Must come
  # before the general ref check below: mr_sql() returns a class
  # c("mr_ref_sql", "mr_ref"), so .mr_is_ref() would match it first
  # and emit the wrong error message.
  if (!inline_mode && inherits(code, "mr_ref_sql")) {
    stop("queue(): SQL staging via mr_sql() is out of scope (v1).", call. = FALSE)
  }

  # Reject other reference objects.
  if (!inline_mode && .mr_is_ref(code)) {
    stop(sprintf(
      "queue(): mr_%s() is not accepted as a first-argument reference. queue() stages new runs; re-queueing an existing stored run is incoherent.",
      code$kind
    ), call. = FALSE)
  }

  if (inline_mode) {
    code_body <- paste(deparse(script_expr, width.cutoff = 500L), collapse = "\n")
    expr_hash <- .mr_hash_bytes(charToRaw(code_body))
    step      <- sprintf("<inline:%s>", substr(expr_hash, 1L, 12L))
    code_hash <- .mr_code_hash_inline(code_body, list())
  } else {
    stopifnot(is.character(code), length(code) == 1L, nzchar(code))
    if (tolower(tools::file_ext(code)) == "sql") {
      stop("queue(): SQL file staging is out of scope (v1).", call. = FALSE)
    }
    if (!file.exists(code)) {
      stop(sprintf("queue(): file not found: %s", code), call. = FALSE)
    }
    step      <- normalizePath(code, mustWork = TRUE)
    code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
    code_hash <- .mr_code_hash(step, list())
  }

  label <- .mr_validate_label(label)

  if (!is.null(duckdb_seed)) {
    if (!is.numeric(duckdb_seed) || length(duckdb_seed) != 1L || is.na(duckdb_seed)) {
      stop("queue(): duckdb_seed must be a single numeric value.", call. = FALSE)
    }
    if (duckdb_seed < -1 || duckdb_seed > 1) {
      stop(sprintf("queue(): duckdb_seed must be in [-1, 1]; got %s.", duckdb_seed),
           call. = FALSE)
    }
  }

  .mr_get_connection()

  # Batch path: dispatch before resolving rebinds. Each envelope is
  # resolved individually inside .mr_queue_batch(), mirroring the
  # launch() batch dispatcher which also skips the top-level resolve
  # when rebind is an mr_binds object.
  if (inherits(rebind, "mr_binds")) {
    return(invisible(.mr_queue_batch(
      step        = step,
      code_body   = code_body,
      code_hash   = code_hash,
      envelopes   = unclass(rebind),
      label       = label,
      duckdb_seed = duckdb_seed
    )))
  }

  # Resolve rebinds at queue time so the JSON provenance reflects what
  # the user passed (matches launch()'s recording behavior).
  resolved_rebinds <- .mr_resolve_rebinds(rebind)

  run_id <- .mr_new_run_id()
  row <- .mr_write_run_row(
    step            = step,
    run_id          = run_id,
    inputs          = list(),
    outputs         = list(),
    started_at      = NA,
    duration_ms     = NA_integer_,
    status          = "queued",
    code_hash       = code_hash,
    external_inputs = list(files = list(), env = list()),
    helpers         = list(),
    variant_label   = label,
    code_body       = code_body,
    duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
    rebinds         = resolved_rebinds$provenance,
    batch_id        = NA_character_,
    session_info    = .mr_blank_session_info()
  )
  invisible(row)
}

# Blank session-context list (all NA), used by queue() so the
# session-context columns reflect "unknown — pickup will populate."
# Field set must match what .mr_capture_session_info() returns; see
# R/session_info.R. After the eddb3a8 git-info commit this includes
# git_sha / git_branch / git_dirty.
.mr_blank_session_info <- function() {
  list(
    hostname          = NA_character_,
    os                = NA_character_,
    arch              = NA_character_,
    r_version         = NA_character_,
    n_cpu             = NA_integer_,
    total_ram_bytes   = NA_real_,
    free_ram_bytes    = NA_real_,
    attached_packages = NA_character_,
    git_sha           = NA_character_,
    git_branch        = NA_character_,
    git_dirty         = NA_character_
  )
}

# Batch helper for queue(). Writes N queued rows (one per envelope) to
# _mr_runs, all sharing one batch_id. Per-envelope rebinds are resolved
# here, mirroring the per-envelope resolution loop in .mr_launch_batch().
.mr_queue_batch <- function(step, code_body, code_hash, envelopes,
                            label, duckdb_seed) {
  n <- length(envelopes)
  if (n == 0L) {
    stop("queue(): mr_binds() expanded to zero envelopes.", call. = FALSE)
  }
  batch_id <- .mr_new_batch_id()
  rows <- vector("list", n)
  for (i in seq_along(envelopes)) {
    env <- envelopes[[i]]
    # Envelope's .label takes precedence over the queue-level label
    # (same precedence as .mr_launch_batch()). Validate the envelope
    # label only when the envelope supplies one; the queue-level label
    # was already validated in queue() before dispatch.
    env_label <- if (".label" %in% names(env)) {
      .mr_validate_label(env$.label)
    } else {
      label
    }
    env_rebind <- env[setdiff(names(env), ".label")]
    if (length(env_rebind) == 0L) env_rebind <- list()
    resolved   <- .mr_resolve_rebinds(env_rebind)
    run_id     <- .mr_new_run_id()
    rows[[i]]  <- .mr_write_run_row(
      step            = step,
      run_id          = run_id,
      inputs          = list(),
      outputs         = list(),
      started_at      = NA,
      duration_ms     = NA_integer_,
      status          = "queued",
      code_hash       = code_hash,
      external_inputs = list(files = list(), env = list()),
      helpers         = list(),
      variant_label   = env_label,
      code_body       = code_body,
      duckdb_seed     = if (is.null(duckdb_seed)) NA_real_ else duckdb_seed,
      rebinds         = resolved$provenance,
      batch_id        = batch_id,
      session_info    = .mr_blank_session_info()
    )
  }
  do.call(rbind, rows)
}
