# Queue + Launch Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the first-argument dispatch + body-capture ladder shared by `launch()` and `queue()` into one internal helper, then broaden `queue()`'s acceptance set so `queue(mr_label(...))` and `queue(mr_run(id))` work — closing the user-facing gap that forces re-supplying body inline in final_practicum's placebo flows.

**Architecture:** Two parts in order. Part 1 is a pure refactor: a new internal `R/dispatch_code.R` exposes `.mr_dispatch_code_arg()` with acceptance policy as parameters, and `launch()` / `queue()` both call it. No user-visible behavior change. Part 2 flips `queue()`'s `accept_refs` from empty to `c("label","run")`, adds the queued-source policy block, and adds the non-success-source warn policy. New tests cover the opened paths.

**Tech Stack:** R 4.5, testthat 3, devtools, roxygen2 (markdown). All work happens in `R/`, `tests/testthat/`, `man/` (regenerated via `devtools::document()`), `vignettes/`, and `NEWS.md`.

**Spec:** [`docs/superpowers/specs/2026-04-29-queue-launch-unification-design.md`](../specs/2026-04-29-queue-launch-unification-design.md)

**Pinned test that becomes obsolete:** `tests/testthat/test-queue.R:119` and `:126` (both expect `expect_error(..., "not accepted as a first-argument reference")` — Part 2 deletes them and replaces with positive tests). Line `:133` (`queue(mr_hash())`) stays as a rejection test, with possibly-updated wording (the new dispatcher message preserves the substring `"not accepted"` so the matcher continues to work).

---

## Part 1 — Shared dispatcher (refactor only)

### Task 1: Create `.mr_dispatch_code_arg()` (unwired)

**Files:**
- Create: `R/dispatch_code.R`

This task adds the helper but does not yet wire it into `launch()` or `queue()`. Existing tests stay green because the existing code paths in `launch.R` and `queue.R` are untouched.

- [ ] **Step 1: Create `R/dispatch_code.R`**

```r
## Internal: shared first-argument dispatcher for launch() and queue().
##
## Both verbs accept (a subset of) the same first-argument shapes — a
## braced inline block, an .R file path, an .sql file path, mr_sql(),
## mr_label(), mr_run(), mr_hash(). Each verb's dispatch ladder then
## branches on shape, captures step + code_body, and rejects shapes
## outside its accept set. This helper consolidates the ladder so the
## accept set becomes a parameter and both verbs share one
## implementation.
##
## Inputs:
##   code         the value bound to the caller's `code` parameter.
##   script_expr  the unevaluated expression captured by the caller via
##                substitute(code), used to detect a literal `{ ... }`.
##   accept_refs  character vector, subset of c("label", "run"). Names
##                of mr_ref kinds the caller accepts as a first arg.
##                mr_hash() is never accepted as a first arg.
##   accept_sql   TRUE if the caller accepts .sql paths and mr_sql().
##   caller       "launch" or "queue", used only to compose error
##                messages.
##
## Returns a list with:
##   kind        one of "inline", "file", "sql_inline", "sql_file",
##               "ref_label", "ref_run".
##   inline_mode TRUE iff kind == "inline".
##   step        "<inline:hash>" or normalized path or
##               resolver-provided step.
##   code_body   the body text (verbatim, from disk, or from
##               snapshot via the resolver fallback).
##   code_hash   set for non-ref kinds; NULL for ref kinds (the
##               caller computes from the resolver's body using the
##               appropriate inline-vs-file rule, see spec).
##   ref         NULL for non-ref kinds; for ref kinds, the resolver's
##               full return list (step, code_body, expr,
##               variant_label [run-only], status [run-only]).
.mr_dispatch_code_arg <- function(code, script_expr,
                                  accept_refs = character(0),
                                  accept_sql  = FALSE,
                                  caller      = "launch") {
  inline_mode <- is.call(script_expr) &&
    identical(script_expr[[1]], as.name("{"))

  if (inline_mode) {
    code_body <- paste(deparse(script_expr, width.cutoff = 500L),
                       collapse = "\n")
    expr_hash <- .mr_hash_bytes(charToRaw(code_body))
    step      <- sprintf("<inline:%s>", substr(expr_hash, 1L, 12L))
    code_hash <- .mr_code_hash_inline(code_body, list())
    return(list(
      kind        = "inline",
      inline_mode = TRUE,
      step        = step,
      code_body   = code_body,
      code_hash   = code_hash,
      ref         = NULL
    ))
  }

  # mr_sql() check must precede the general .mr_is_ref() branch:
  # mr_sql() returns class c("mr_ref_sql", "mr_ref"), so the general
  # ref branch would otherwise match it first with the wrong message.
  if (inherits(code, "mr_ref_sql")) {
    if (!accept_sql) {
      stop(sprintf(
        "%s(): SQL staging via mr_sql() is out of scope (v1).", caller
      ), call. = FALSE)
    }
    return(list(
      kind        = "sql_inline",
      inline_mode = FALSE,
      step        = NA_character_,    # SQL path computes its own step
      code_body   = code$body,
      code_hash   = NULL,
      ref         = NULL
    ))
  }

  if (.mr_is_ref(code)) {
    if (!(code$kind %in% accept_refs)) {
      # Compose the rejection message in launch's existing style if the
      # caller is launch (mentions which refs ARE accepted), and in
      # queue's existing style otherwise (says the kind is not accepted
      # as a first-argument reference).
      if (identical(caller, "launch")) {
        stop(sprintf(
          "%s(): only %s are accepted as first argument references; got mr_%s().",
          caller,
          paste(sprintf("mr_%s()", accept_refs), collapse = " and "),
          code$kind
        ), call. = FALSE)
      } else {
        stop(sprintf(
          "%s(): mr_%s() is not accepted as a first-argument reference.",
          caller, code$kind
        ), call. = FALSE)
      }
    }

    if (identical(code$kind, "label")) {
      resolved <- .mr_resolve_relaunch(code$value)
      return(list(
        kind        = "ref_label",
        inline_mode = FALSE,
        step        = resolved$step,
        code_body   = resolved$code_body,
        code_hash   = NULL,
        ref         = resolved
      ))
    }
    if (identical(code$kind, "run")) {
      resolved <- .mr_resolve_relaunch_run_id(code$value)
      return(list(
        kind        = "ref_run",
        inline_mode = FALSE,
        step        = resolved$step,
        code_body   = resolved$code_body,
        code_hash   = NULL,
        ref         = resolved
      ))
    }
    # Defensive: accept_refs is filtered to c("label","run") above; an
    # accept_refs entry outside that pair would land here.
    stop(sprintf(
      "%s(): internal error — accept_refs entry '%s' not handled.",
      caller, code$kind
    ), call. = FALSE)
  }

  # Character path. Validate shape, then route on extension.
  stopifnot(is.character(code), length(code) == 1L, nzchar(code))
  ext <- tolower(tools::file_ext(code))
  if (ext == "sql") {
    if (!accept_sql) {
      stop(sprintf(
        "%s(): SQL file staging is out of scope (v1).", caller
      ), call. = FALSE)
    }
    return(list(
      kind        = "sql_file",
      inline_mode = FALSE,
      step        = NA_character_,
      code_body   = NA_character_,
      code_hash   = NULL,
      ref         = NULL
    ))
  }

  if (!file.exists(code)) {
    stop(sprintf("%s(): file not found: %s", caller, code), call. = FALSE)
  }
  step      <- normalizePath(code, mustWork = TRUE)
  code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
  code_hash <- .mr_code_hash(step, list())
  list(
    kind        = "file",
    inline_mode = FALSE,
    step        = step,
    code_body   = code_body,
    code_hash   = code_hash,
    ref         = NULL
  )
}
```

- [ ] **Step 2: Verify the helper loads**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::load_all(".", quiet = TRUE); exists(".mr_dispatch_code_arg", envir = asNamespace("modelrunnR"), inherits = FALSE)'`

Expected output: `[1] TRUE`

- [ ] **Step 3: Run the full test suite — should be green (helper unused)**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test()'`

Expected: all tests pass, no new failures. If any test fails, stop and investigate before continuing.

- [ ] **Step 4: Commit**

```bash
cd /workspace/r-packages/modelrunnR
git add R/dispatch_code.R
git commit -m "refactor(dispatch): introduce shared .mr_dispatch_code_arg() helper

Unwired in this commit; rewires of launch() and queue() follow.
Spec: docs/superpowers/specs/2026-04-29-queue-launch-unification-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rewire `queue()` to call the dispatcher

**Files:**
- Modify: `R/queue.R` (replace lines 74–109, the dispatch+body-capture ladder)

- [ ] **Step 1: Replace the dispatch ladder in `queue()`**

In `R/queue.R`, replace the block from `script_expr <- substitute(code)` through the close of the file-step `else` branch (currently the body capture ending at `code_hash <- .mr_code_hash(step, list())`) with the dispatcher call. Open `R/queue.R` and find this block (current behavior, for reference; this is what gets removed):

```r
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
```

Replace it with:

```r
  script_expr <- substitute(code)

  dispatch <- .mr_dispatch_code_arg(
    code         = code,
    script_expr  = script_expr,
    accept_refs  = character(0),   # Part 2 flips this
    accept_sql   = FALSE,
    caller       = "queue"
  )
  inline_mode <- dispatch$inline_mode
  step        <- dispatch$step
  code_body   <- dispatch$code_body
  code_hash   <- dispatch$code_hash
```

- [ ] **Step 2: Run the queue test file**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test(filter = "queue")'`

Expected: all `test-queue.R` and `test-queue-pickup.R` tests pass. The pinned `expect_error(..., "not accepted as a first-argument reference")` matcher continues to match because the new dispatcher message contains that substring. The pinned `expect_error(..., "out of scope")` and `expect_error(..., "file not found")` matchers continue to match for the same reason.

- [ ] **Step 3: Run the full suite**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test()'`

Expected: full green.

- [ ] **Step 4: Commit**

```bash
cd /workspace/r-packages/modelrunnR
git add R/queue.R
git commit -m "refactor(queue): route first-arg dispatch through .mr_dispatch_code_arg()

Part 1 of queue+launch unification. Behavior-preserving: accept_refs
stays empty; SQL stays rejected. Tests untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rewire `launch()` to call the dispatcher

**Files:**
- Modify: `R/launch.R` (replace the dispatch+body-capture ladder around lines 201–342)

This rewire is more involved than queue's because launch routes into SQL, queued-pickup, and relaunch-nonsuccess policy paths after dispatch. The dispatcher returns enough info for all of them.

- [ ] **Step 1: Replace the dispatch ladder in `launch()`**

In `R/launch.R`, find the block starting at `inline_mode <- is.call(script_expr) && identical(script_expr[[1]], as.name("{"))` (around line 205) through the end of the body-capture block (around line 342, ending with the file-mode `code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")`).

Replace that block with:

```r
  dispatch <- .mr_dispatch_code_arg(
    code         = code,
    script_expr  = script_expr,
    accept_refs  = c("label", "run"),
    accept_sql   = TRUE,
    caller       = "launch"
  )

  inline_mode    <- dispatch$inline_mode
  step           <- dispatch$step
  code_body      <- dispatch$code_body
  is_inline_sql  <- identical(dispatch$kind, "sql_inline")
  is_file_sql    <- identical(dispatch$kind, "sql_file")
  relaunch_mode  <- dispatch$kind %in% c("ref_label", "ref_run")
  relaunch_kind  <- if (relaunch_mode) sub("^ref_", "", dispatch$kind) else NULL
  resolved       <- dispatch$ref           # NULL for non-ref kinds
  relaunch_expr  <- if (relaunch_mode) resolved$expr else NULL

  # SQL dispatch — same shape as before, but body/path now come from
  # the dispatcher.
  if (is_inline_sql || is_file_sql) {
    src_kind     <- if (is_inline_sql) "inline" else "file"
    body_or_path <- if (is_inline_sql) dispatch$code_body else code

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
    .mr_state$pending_shape_b_filters <- NULL
    skip_on_fresh      <- isTRUE(getOption("modelrunnR.skip_if_fresh", TRUE))
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

  # Relaunch label inheritance (auto-inherit unless caller passed label=).
  if (relaunch_mode && is.na(label)) {
    label <- if (identical(relaunch_kind, "label")) {
      code$value
    } else {
      resolved$variant_label
    }
  }

  # Non-success source policy for mr_run() relaunches.
  if (relaunch_mode && identical(relaunch_kind, "run") &&
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
```

The remaining launch.R logic (queued-row pickup at line ~362, batch dispatch at line ~389, `.mr_launch_one()` call at line ~406) stays untouched. The dispatcher's outputs (`step`, `code_body`, `inline_mode`, `relaunch_mode`, `relaunch_expr`, `resolved`) are the same names/shapes those downstream blocks already consume.

- [ ] **Step 2: Run launch test files**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test(filter = "launch")'`

Expected: all `test-launch*.R` tests pass.

- [ ] **Step 3: Run the full suite**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test()'`

Expected: full green. If any test fails, stop and inspect — Part 1 is supposed to be byte-equivalent.

- [ ] **Step 4: Commit**

```bash
cd /workspace/r-packages/modelrunnR
git add R/launch.R
git commit -m "refactor(launch): route first-arg dispatch through .mr_dispatch_code_arg()

Part 1 of queue+launch unification. Behavior-preserving: launch keeps
accept_refs = c('label','run') and accept_sql = TRUE. Tests untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Part 2 — Broaden `queue()`'s acceptance set

### Task 4: Add failing tests for the new accept paths

**Files:**
- Modify: `tests/testthat/test-queue.R` (add new test blocks at the bottom; keep existing tests intact for now — Task 6 prunes the obsolete ones)

- [ ] **Step 1: Add new test blocks at the end of `tests/testthat/test-queue.R`**

```r
test_that("queue(mr_label('x')) stages a queued row carrying the labeled body", {
  con <- .mr_get_connection()
  new_test_db()

  # Seed a labeled run so mr_label("seed") resolves to something.
  launch({ stow(1L, "out_a") }, label = "seed")

  q <- queue(mr_label("seed"))
  expect_equal(q$status, "queued")
  expect_match(q$code_body, "stow(1L", fixed = TRUE)
  # Auto-inherits label from the ref unless overridden.
  expect_equal(q$variant_label, "seed")
})

test_that("queue(mr_label(...), label = 'override') uses the caller's label", {
  new_test_db()
  launch({ stow(1L, "out_b") }, label = "seed2")

  q <- queue(mr_label("seed2"), label = "new_thread")
  expect_equal(q$variant_label, "new_thread")
})

test_that("queue(mr_run(id)) against a success row writes a fresh queued row", {
  new_test_db()
  src <- launch({ stow(1L, "out_c") })

  q <- queue(mr_run(src$run_id))
  expect_equal(q$status, "queued")
  expect_false(identical(q$run_id, src$run_id))
  expect_match(q$code_body, "stow(1L", fixed = TRUE)
})

test_that("queue(mr_run(qid)) against a queued source with no rebind errors as circular", {
  new_test_db()
  q1 <- queue({ stow(1L, "out_d") })

  expect_error(
    queue(mr_run(q1$run_id)),
    "circular"
  )
})

test_that("queue(mr_run(qid)) against a queued source WITH rebind succeeds and leaves source queued", {
  new_test_db()
  q1 <- queue({ stow(grab("x"), "out_e") }, rebind = list(x = 1L))

  q2 <- queue(mr_run(q1$run_id), rebind = list(x = 2L))
  expect_equal(q2$status, "queued")
  expect_false(identical(q2$run_id, q1$run_id))

  # Source stays queued.
  con <- .mr_get_connection()
  src <- DBI::dbGetQuery(
    con, "SELECT status FROM _mr_runs WHERE run_id = ?",
    params = list(q1$run_id)
  )
  expect_equal(src$status, "queued")
})

test_that("queue(mr_run(failed_id)) warns under default relaunch_nonsuccess policy", {
  new_test_db()
  on.exit(options(modelrunnR.relaunch_nonsuccess = NULL), add = TRUE)

  src <- tryCatch(launch({ stop("boom") }), error = function(e) NULL)
  failed_id <- DBI::dbGetQuery(
    .mr_get_connection(),
    "SELECT run_id FROM _mr_runs WHERE status = 'error' ORDER BY started_at DESC LIMIT 1"
  )$run_id[1]

  expect_warning(
    queue(mr_run(failed_id)),
    "status 'error'"
  )
})

test_that("queue(mr_label('x'), rebind = mr_binds(...)) fans out as a queued batch", {
  new_test_db()
  launch({ stow(grab("alpha"), "out_f") },
         rebind = list(alpha = 0.1),
         label  = "seed3")

  qs <- queue(
    mr_label("seed3"),
    rebind = mr_binds(alpha = c(0.1, 0.5, 1.0))
  )
  expect_equal(nrow(qs), 3L)
  expect_true(all(qs$status == "queued"))
  expect_equal(length(unique(qs$batch_id)), 1L)
  expect_true(all(qs$variant_label == "seed3"))
})
```

The setup helper used elsewhere in `test-queue.R` is `new_test_db()` (called at the top of each `test_that(...)` block). Each test gets a fresh DB; teardown happens implicitly between tests.

- [ ] **Step 2: Run the new tests — they should all fail**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test(filter = "queue")'`

Expected: the 7 new test blocks fail (queue still rejects ref first-args). The pre-existing tests (including the rejection tests at lines 119/126) still pass.

- [ ] **Step 3: Commit the failing tests**

```bash
cd /workspace/r-packages/modelrunnR
git add tests/testthat/test-queue.R
git commit -m "test(queue): add failing tests for mr_label/mr_run first-arg acceptance

Pre-implementation TDD checkpoint. Tests cover label inheritance,
queued-source circular case, queued-source-with-rebind, non-success
source warning, and ref-batch fan-out. All currently fail because
queue() still rejects ref first-args.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Flip `accept_refs` and add the queue policy block

**Files:**
- Modify: `R/queue.R` (the dispatcher call from Task 2 plus a new policy block)

- [ ] **Step 1: Update the dispatcher call and add the policy block in `queue()`**

In `R/queue.R`, find the dispatcher call from Task 2:

```r
  dispatch <- .mr_dispatch_code_arg(
    code         = code,
    script_expr  = script_expr,
    accept_refs  = character(0),   # Part 2 flips this
    accept_sql   = FALSE,
    caller       = "queue"
  )
  inline_mode <- dispatch$inline_mode
  step        <- dispatch$step
  code_body   <- dispatch$code_body
  code_hash   <- dispatch$code_hash
```

Replace it with:

```r
  dispatch <- .mr_dispatch_code_arg(
    code         = code,
    script_expr  = script_expr,
    accept_refs  = c("label", "run"),
    accept_sql   = FALSE,
    caller       = "queue"
  )
  inline_mode   <- dispatch$inline_mode
  step          <- dispatch$step
  code_body     <- dispatch$code_body
  relaunch_mode <- dispatch$kind %in% c("ref_label", "ref_run")
  relaunch_kind <- if (relaunch_mode) sub("^ref_", "", dispatch$kind) else NULL
  resolved      <- dispatch$ref

  # code_hash for ref kinds: match what launch() would have written.
  # See spec §"Resolution" for the inline-vs-file rule.
  code_hash <- if (relaunch_mode) {
    if (startsWith(step, "<inline:")) {
      .mr_code_hash_inline(code_body, list())
    } else if (file.exists(step)) {
      .mr_code_hash(step, list())
    } else {
      # Resolver fell back to the snapshot; hash over the snapshot.
      .mr_code_hash_inline(code_body, list())
    }
  } else {
    dispatch$code_hash
  }

  # Queued-source circular check (mr_run only). Rejects re-queueing a
  # queued row with no changes; rebind = ... opens the template path.
  if (relaunch_mode && identical(relaunch_kind, "run") &&
      identical(resolved$status, "queued") &&
      is.null(rebind)) {
    stop(sprintf(
      "queue(mr_run('%s')): the source row is itself queued and no rebind was supplied. Re-queueing a queued run with no changes is circular. Either supply rebind = ... to stage a variant, or drain the queued row first via launch(mr_run('%s')).",
      code$value, code$value
    ), call. = FALSE)
  }

  # Non-success source policy (mr_run only). Mirrors launch().
  if (relaunch_mode && identical(relaunch_kind, "run") &&
      !is.na(resolved$status) &&
      !identical(resolved$status, "success") &&
      !identical(resolved$status, "queued")) {
    policy <- match.arg(
      getOption("modelrunnR.relaunch_nonsuccess", "warn"),
      c("warn", "error", "silent")
    )
    msg <- sprintf(
      "queue(): staging from run_id '%s' whose source row has status '%s'.",
      code$value, resolved$status
    )
    if (identical(policy, "error")) {
      stop(paste(msg, "Set options(modelrunnR.relaunch_nonsuccess = \"warn\") to stage anyway."),
           call. = FALSE)
    }
    if (identical(policy, "warn")) warning(msg, call. = FALSE)
  }

  # Label inheritance for refs. Caller's `label` wins; otherwise inherit
  # from the label ref's value (mr_label) or source row's variant_label
  # (mr_run). This must happen BEFORE the existing .mr_validate_label()
  # call so the inherited value is also validated.
  if (relaunch_mode && is.null(label)) {
    label <- if (identical(relaunch_kind, "label")) {
      code$value
    } else {
      # mr_run: source row's variant_label may be NA (unlabeled run)
      vl <- resolved$variant_label
      if (is.na(vl)) NULL else vl
    }
  }
```

Note the `is.null(label)` check (rather than `is.na(label)`): in `queue()`, the function signature has `label = NULL`; the existing `label <- .mr_validate_label(label)` call below converts `NULL` to `NA_character_`. The inheritance must run before that conversion so we substitute the inherited value before NA-ifying.

- [ ] **Step 2: Run the queue tests**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test(filter = "queue")'`

Expected: the 7 new tests now pass. The two old `expect_error(..., "not accepted as a first-argument reference")` tests at lines 119, 126 now FAIL (queue accepts those refs). That's expected — Task 6 deletes those.

- [ ] **Step 3: Commit**

```bash
cd /workspace/r-packages/modelrunnR
git add R/queue.R
git commit -m "feat(queue): accept mr_label() and mr_run() as first-arg references

Part 2 of queue+launch unification. queue(mr_label('x')) stages a
queued row carrying the labeled body. queue(mr_run(id)) stages a fresh
queued row carrying that run's body. Queued-source-with-no-rebind is
the only remaining circular case and errors with a clear message.

Closes the user-facing gap that forced re-supplying body inline in
final_practicum's placebo flows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Remove obsolete rejection tests

**Files:**
- Modify: `tests/testthat/test-queue.R`

- [ ] **Step 1: Delete the now-incorrect rejection tests**

Open `tests/testthat/test-queue.R`. Find the two `test_that(...)` blocks containing:

```r
expect_error(queue(mr_run(r$run_id)), "not accepted as a first-argument reference")
```

and

```r
expect_error(queue(mr_label("foo")), "not accepted as a first-argument reference")
```

Delete both blocks entirely (the `test_that(...)` wrappers and their setup). They previously asserted rejection; the positive-path tests added in Task 4 cover the new behavior.

The block containing `expect_error(queue(mr_hash("abc")), "not accepted as a first-argument reference")` **stays** — `mr_hash()` is still rejected. Verify the matcher `"not accepted as a first-argument reference"` still hits the new dispatcher's message. The dispatcher's queue-mode rejection message is `"queue(): mr_<kind>() is not accepted as a first-argument reference."` — the substring matches. If for any reason the test fails, update the matcher to `"not accepted"` (still distinctive).

- [ ] **Step 2: Run the queue tests**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test(filter = "queue")'`

Expected: full green for queue tests.

- [ ] **Step 3: Run the full suite**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::test()'`

Expected: full green.

- [ ] **Step 4: Commit**

```bash
cd /workspace/r-packages/modelrunnR
git add tests/testthat/test-queue.R
git commit -m "test(queue): remove obsolete rejection tests for mr_label/mr_run

These now succeed; positive-path coverage was added in the prior commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Update `queue()` roxygen, NEWS, and vignette

**Files:**
- Modify: `R/queue.R` (roxygen header, `@param code`)
- Modify: `NEWS.md`
- Modify: vignette mentioning queue (search `vignettes/`)
- Regenerate: `man/queue.Rd` via `devtools::document()`

- [ ] **Step 1: Update `R/queue.R` roxygen `@param code`**

In `R/queue.R`, find the `@param code` block:

```r
#' @param code A braced `{ ... }` block (inline) or a path to an
#'   `.R` script (file step). Reference objects ([mr_run()],
#'   [mr_label()], [mr_hash()]) and `.sql` paths / [mr_sql()] are
#'   rejected — re-queueing or staging SQL is out of scope.
```

Replace with:

```r
#' @param code A braced `{ ... }` block (inline), a path to an `.R`
#'   script (file step), [mr_label()] (stages the labeled pipeline's
#'   body), or [mr_run()] (stages a specific run's body). `.sql` paths,
#'   [mr_sql()], and [mr_hash()] are rejected — SQL queueing is out of
#'   scope (v1) and `mr_hash()` addresses content, not pipelines.
#'
#'   `mr_label()` resolution mirrors `launch(mr_label(...))`: re-reads
#'   the file from disk for file steps; uses the stored snapshot for
#'   inline steps. The label is auto-inherited onto the queued row
#'   unless `label = ...` is passed.
#'
#'   `mr_run()` resolution mirrors `launch(mr_run(id))` for
#'   non-queued sources: a new queued row is written from that run's
#'   body. The source row's `variant_label` is auto-inherited unless
#'   `label = ...` is passed. Against a queued source: with `rebind =
#'   ...` the queued row is treated as a template (parallels
#'   `launch(mr_run(qid), rebind = ...)`); without `rebind`, errors
#'   as circular.
```

- [ ] **Step 2: Add a NEWS bullet**

Open `NEWS.md`. Under the next development version's section (create one if needed), add:

```markdown
* `queue()` now accepts `mr_label()` and `mr_run()` as first-argument
  references, mirroring `launch()`. This stages a queued row carrying the
  resolved body — useful for batching re-runs of an existing labeled
  pipeline or specific historical run for later parallel execution. The
  only remaining circular case (`queue(mr_run(qid))` against a queued
  source with no rebind) errors with a clear message.
* Internal: `launch()` and `queue()` now share a single first-argument
  dispatcher (`.mr_dispatch_code_arg()`). No user-visible behavior change
  from the refactor.
```

- [ ] **Step 3: Add a vignette note next to the existing batch example**

Find the vignette section that introduces `queue()`:

Run: `cd /workspace/r-packages/modelrunnR && grep -rln "queue(" vignettes/`

Open the matching vignette. After the existing batch example (`queue({ ... }, rebind = mr_binds(...))`), insert a short subsection:

````markdown
### Queueing a re-run

`queue()` accepts the same reference shapes as `launch()`'s relaunch
mode. Use `mr_label()` to stage a labeled pipeline's body for later
execution under different bindings:

```r
launch({ ... }, label = "ridge_pf")

queue(
  mr_label("ridge_pf"),
  rebind = mr_binds(panel = list(mr_variant("placebo_panel"))),
  label  = "ridge_pbo"
)
```

`mr_run(id)` works the same way against a specific historical run.
````

The exact wording / fence depth should match the surrounding vignette style.

- [ ] **Step 4: Regenerate `man/queue.Rd`**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::document()'`

Expected output: roxygen2 reports `Writing 'queue.Rd'` (and possibly other regenerations from doc-comment fixups).

- [ ] **Step 5: Run R CMD check**

Run: `cd /workspace/r-packages/modelrunnR && Rscript -e 'devtools::check()'`

Expected: 0 errors, 0 warnings. Notes acceptable if they were already there. If a new note appears, investigate.

- [ ] **Step 6: Commit**

```bash
cd /workspace/r-packages/modelrunnR
git add R/queue.R man/queue.Rd NEWS.md vignettes/
git commit -m "docs(queue): document mr_label/mr_run first-arg acceptance

Roxygen, NEWS, and vignette updates for the queue+launch unification.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Manual smoke test (not a unit test)

- [ ] **Step 1: Rewrite one cprice placebo section to use `queue()` and drain it**

Open `/workspace/practicum_repos/final_practicum/qmd/concurrent_price.qmd`. Find the ridge placebo block (around line 325):

```r
launch(
  code = mr_label("cprice_ridge__pf"),
  rebind = mr_binds(...),
  label = "cprice_ridge__pbo"
)
```

In an R session (not the rendered qmd), run:

```r
qs <- queue(
  code = mr_label("cprice_ridge__pf"),
  rebind = mr_binds(test_year = windows$test_year, ...),
  label = "cprice_ridge__pbo"
)

# Drain serially to confirm pickup works.
purrr::walk(qs$run_id, ~ launch(mr_run(.x)))

# Verify rows are in _mr_runs with status = success.
runs() |>
  dplyr::filter(variant_label == "cprice_ridge__pbo") |>
  dplyr::select(run_id, status, started_at) |>
  print()
```

Expected: N rows (one per window) with `status = "success"` and the same `code_body` substring as the pf body. Do not commit qmd edits — this is a one-off verification.

- [ ] **Step 2: Roll the smoke test back if you scribbled in the qmd**

Run: `cd /workspace/practicum_repos/final_practicum && git status` to confirm no unintended changes.

---

## Self-review checklist (run by the implementer)

- All 7 tasks above committed individually.
- `devtools::test()` green.
- `devtools::check()` green (0 errors, 0 warnings).
- Spec §"Verification" checklist items all covered:
  - `R CMD check` clean → Task 7 step 5
  - Existing tests pass without modification → Tasks 2, 3
  - New positive-path tests for `queue(mr_label/mr_run)` → Task 4
  - Circular-source test → Task 4
  - Non-success warn test → Task 4
  - Label inheritance test → Task 4
  - Batch fan-out via ref → Task 4
  - cprice smoke test → Manual step
- No new exported symbols added (the dispatcher is internal `.mr_*`).
- No schema changes.
