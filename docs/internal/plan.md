# modelrunnR Swappability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer the swappability feature from `docs/design.md` onto the shipped v0.1 package: unify `pin`/`data` into a single polymorphic `rebind` argument, add labeled variants as first-class experimental threads, and expose the variant inspection/management surface.

**Architecture:** Seven vertical slices on top of the existing v0.1 runtime. Slice A adds the `variant_label` column to `_mr_runs` (idempotent migration). Slice B renames the pin/data machinery to `rebind`, adds the `mr_*()` reference constructors, and hard-errors on the old argument names. Slice C adds the `label` argument to `launch()` plus `grab(variant = …)` resolution. Slices D/E add the inspection (`variants()`, `variants_unexplored()`) and management (`prune_versions` label protection, `prune_variants()`) surface. Slice F adds auto-propagation of labels from labeled upstreams. Slice G extends staleness to per-variant and enriches the launch-time summary.

**Tech Stack:** R, DuckDB via DBI, testthat 3e, devtools, roxygen2-markdown.

---

## How to use this plan

- Each slice is **vertical**: it ships something a user could exercise end-to-end before moving on. No slice leaves the package in a state where a previously-working example (under the new vocabulary) stops working.
- Slices are sized for a commit-per-slice cadence at minimum; more granular commits within a slice are encouraged (TDD, frequent commits).
- **Design-doc-first.** If a slice's behavior is unclear, `docs/design.md` is the tiebreaker. This plan does not re-derive semantics — it only sequences.
- **Breaking changes are allowed.** Per CLAUDE.md and the user's direction, the package has no external users; `launch(pin=, data=)` becomes a hard error in Slice B with no compat shim.
- **Every slice ends with `devtools::document()`, `devtools::test()`, and `devtools::check()` clean before commit.**

## Conventions the plan assumes

These match the existing v0.1 codebase; they're restated so the plan is unambiguous.

- Internal helpers use the `.mr_` prefix and are not exported.
- Package-level state lives in `.mr_state` (the internal environment created in `R/zzz.R`).
- Schema migrations are idempotent and run on every connect via `.mr_migrate()` in `R/schema.R`. Use `.mr_add_column_if_missing()` for additive column changes.
- JSON columns are serialized with `jsonlite`.
- User-facing functions get one file each, named after the function (`R/grab.R`, `R/launch.R`, …). Aspect files (`R/schema.R`, `R/recording.R`, `R/rebind.R`) group tightly related internals.
- Tests live in `tests/testthat/test-<topic>.R`. The existing `tests/testthat/helper-testdb.R` provides a fresh in-memory DB per test — reuse it.

## Slice dependency graph

```
 A. schema migration ──> B. rebind + references + hard-error
                            │
                            v
                         C. label + grab(variant=) + mr_variant
                            │
                            v
                   ┌────────┼────────┐
                   v        v        v
          D. variants()   E. prune  F. auto-propagation
                            │        │
                            └───┬────┘
                                v
                           G. per-variant staleness + summary
```

Slices D, E, and F each depend on C but not on each other; they can be built in any order or in parallel worktrees. G depends on all of D/E/F being in place.

## Pre-flight

Before starting Slice A:

```bash
cd /workspace/r-packages/modelrunnR
git status                    # working tree clean on feat/swappability
Rscript -e 'devtools::test()' # baseline v0.1 suite passes
```

If either check fails, stop and diagnose before editing anything.

---

## Slice A — Schema migration: `variant_label` column

**Goal.** Add a nullable `variant_label TEXT` column to `_mr_runs` via the existing idempotent migration path. No behavior change — every run still gets `NULL` for `variant_label` because no slice yet writes to it. This slice is purely additive and keeps the package green.

**Files:**
- Modify: `R/schema.R` — extend `.mr_migrate_runs()` with one more `.mr_add_column_if_missing()` call.
- Modify: `tests/testthat/test-run-record.R` — one new assertion.

- [ ] **Step 1: Write the failing test**

Add this test case to the end of `tests/testthat/test-run-record.R`:

```r
test_that("_mr_runs has a nullable variant_label column", {
  new_test_db()

  con  <- .mr_get_connection()
  info <- DBI::dbGetQuery(con, "PRAGMA table_info(_mr_runs)")
  expect_true("variant_label" %in% info$name)

  # New runs still write NULL until later slices opt in.
  script <- write_script('stow(data.frame(a = 1), "out")')
  launch(script)
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_true(all(is.na(row$variant_label)))
})
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
Rscript -e 'devtools::test(filter = "run-record")'
```

Expected: the new test fails with `"variant_label" %in% info$name is not TRUE`.

- [ ] **Step 3: Add the migration**

In `R/schema.R`, extend `.mr_migrate_runs()` by adding one line after the existing `.mr_add_column_if_missing()` calls:

```r
.mr_migrate_runs <- function(con) {
  sql <- "
    CREATE TABLE IF NOT EXISTS _mr_runs (
      step         TEXT,
      run_id       TEXT,
      inputs       TEXT,
      outputs      TEXT,
      started_at   TIMESTAMP,
      duration_ms  BIGINT,
      status       TEXT
    )
  "
  .mr_execute(con, sql)
  .mr_add_column_if_missing(con, "_mr_runs", "code_hash",       "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "external_inputs", "TEXT")
  .mr_add_column_if_missing(con, "_mr_runs", "helpers",         "TEXT")
  # Swappability (Slice A): nullable label for tracked variants.
  .mr_add_column_if_missing(con, "_mr_runs", "variant_label",   "TEXT")
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
Rscript -e 'devtools::test(filter = "run-record")'
```

Expected: the new test passes and no existing test in this file regresses.

- [ ] **Step 5: Run the full suite and R CMD check**

```bash
Rscript -e 'devtools::document(); devtools::test(); devtools::check()'
```

Expected: all tests pass, `R CMD check` clean.

- [ ] **Step 6: Commit**

```bash
git add R/schema.R tests/testthat/test-run-record.R
git commit -m "feat(swappability-A): add variant_label column to _mr_runs

Idempotent additive migration via .mr_add_column_if_missing(). Every
run still writes NULL until Slice C opts in to labeled variants."
```

---

## Slice B — `rebind` + reference constructors + hard-error on `pin`/`data`

**Goal.** Rename the pin/data machinery to `rebind`, introduce the `mr_hash()`, `mr_run()`, `mr_variant()`, `mr_as_of()` reference constructors, and make `launch(pin=)` / `launch(data=)` a hard error. `mr_variant()` stays unimplemented in this slice (Slice C wires it up); `mr_as_of()` ships fully working because the underlying query is already expressible against `_mr_versions.first_seen`.

**Files:**
- Rename: `R/pin.R` → `R/rebind.R`.
- Modify: `R/rebind.R` — rename internals, add resolver for `mr_*()` tagged references, raise on `mr_variant()` with "not yet implemented".
- Create: `R/references.R` — the four `mr_*()` constructors.
- Modify: `R/launch.R` — signature change, hard-error on old args, call renamed internals.
- Modify: `R/zzz.R` (or wherever `.mr_state` is declared) if it referenced `pins` by name.
- Rename: `tests/testthat/test-pin-data.R` → `tests/testthat/test-rebind.R`.
- Modify: `tests/testthat/test-rebind.R` — rewrite the suite against `rebind = …` and the new constructors.

- [ ] **Step 1: `git mv` the file**

```bash
git mv R/pin.R R/rebind.R
git mv tests/testthat/test-pin-data.R tests/testthat/test-rebind.R
git status
```

Expected: two renames staged, working tree otherwise clean.

- [ ] **Step 2: Write the failing tests for `rebind`**

Replace the contents of `tests/testthat/test-rebind.R` with:

```r
test_that("launch(rebind = list(name = df)) stows bare values", {
  new_test_db()

  script <- write_script(c(
    'p <- grab("params")',
    'stow(data.frame(echo = p$x), "out")'
  ))

  launch(script, rebind = list(params = data.frame(x = 42L)))

  expect_equal(grab("out")$echo, 42L)
})

test_that("launch(rebind) with mr_hash resolves to an existing version", {
  new_test_db()

  stow(data.frame(v = 1:3), "features")
  h <- versions("features")$content_hash[1]

  script <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(n = nrow(f)), "out")'
  ))
  launch(script, rebind = list(features = mr_hash(h)))
  expect_equal(grab("out")$n, 3L)
})

test_that("launch(rebind) with mr_run resolves via run outputs", {
  new_test_db()

  producer <- write_script('stow(data.frame(v = 1:5), "features")')
  run <- launch(producer)

  consumer <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(n = nrow(f)), "out")'
  ))
  launch(consumer, rebind = list(features = mr_run(run$run_id)))
  expect_equal(grab("out")$n, 5L)
})

test_that("launch(rebind) with mr_as_of resolves to latest-as-of-time", {
  new_test_db()

  stow(data.frame(v = 1L), "features")
  t0 <- Sys.time()
  Sys.sleep(0.05)
  stow(data.frame(v = 2L), "features")

  script <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(v = f$v), "out")'
  ))
  launch(script, rebind = list(features = mr_as_of(t0)))
  expect_equal(grab("out")$v, 1L)
})

test_that("launch(pin = ...) is a hard error with a migration message", {
  expect_error(
    launch("nonexistent.R", pin = list(p = "abc")),
    regexp = "pin.*removed.*rebind",
    fixed = FALSE
  )
})

test_that("launch(data = ...) is a hard error with a migration message", {
  expect_error(
    launch("nonexistent.R", data = list(p = data.frame(x = 1))),
    regexp = "data.*removed.*rebind",
    fixed = FALSE
  )
})

test_that("mr_variant constructor exists but errors at resolution time", {
  new_test_db()

  script <- write_script('stow(data.frame(a = 1), "out")')
  expect_error(
    launch(script, rebind = list(features = mr_variant("foo"))),
    regexp = "mr_variant.*not yet",
    fixed = FALSE
  )
})
```

- [ ] **Step 3: Run the new tests to verify they fail**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "rebind")'
```

Expected: all seven tests fail — `launch()` still has `pin`/`data` parameters, `rebind` is unknown, `mr_hash`/`mr_run`/`mr_variant`/`mr_as_of` are undefined.

- [ ] **Step 4: Create `R/references.R` with the four constructors**

```r
#' Reference constructors for `launch(rebind = list(...))`
#'
#' Small, structured wrappers for addressing existing modelrunnR
#' versions by identity instead of inlining R values in
#' `launch(rebind = list(...))`. Each returns a tagged list that
#' `launch()` resolves to a content hash before recording starts.
#'
#' Use a bare R value in `rebind` when you want the value stowed
#' inline; use one of these constructors when you want to address
#' something already stored.
#'
#' @param hash A content hash string (from `versions()`).
#' @param run_id A run id string (from `_mr_runs`).
#' @param label A variant label string.
#' @param time A timestamp (`POSIXct`) or a string parseable by
#'   `as.POSIXct`.
#' @return A tagged list for `launch()` to resolve.
#' @name references
NULL

#' @rdname references
#' @export
mr_hash <- function(hash) {
  stopifnot(is.character(hash), length(hash) == 1L, nzchar(hash))
  structure(list(kind = "hash", value = hash), class = "mr_ref")
}

#' @rdname references
#' @export
mr_run <- function(run_id) {
  stopifnot(is.character(run_id), length(run_id) == 1L, nzchar(run_id))
  structure(list(kind = "run", value = run_id), class = "mr_ref")
}

#' @rdname references
#' @export
mr_variant <- function(label) {
  stopifnot(is.character(label), length(label) == 1L, nzchar(label))
  structure(list(kind = "variant", value = label), class = "mr_ref")
}

#' @rdname references
#' @export
mr_as_of <- function(time) {
  if (is.character(time)) time <- as.POSIXct(time)
  stopifnot(inherits(time, "POSIXct"), length(time) == 1L)
  structure(list(kind = "as_of", value = time), class = "mr_ref")
}

.mr_is_ref <- function(x) inherits(x, "mr_ref")
```

- [ ] **Step 5: Rewrite `R/rebind.R`**

Replace the entire contents of `R/rebind.R` (formerly `R/pin.R`) with:

```r
## `rebind` resolution for launch().
##
## `rebind` is a named list whose values are either:
##   - a bare R value (data frame or arbitrary R object), stowed into
##     DuckDB through the normal stow pathway so its content_hash
##     becomes the bound value, or
##   - a tagged reference from mr_hash()/mr_run()/mr_variant()/mr_as_of(),
##     resolved to an existing content_hash without round-tripping
##     through R memory.
##
## The resolved map (name -> content_hash) lives in .mr_state$rebinds
## for the duration of the launch and overrides default grab()
## resolution.

.mr_start_rebinding <- function(rebinds) {
  .mr_state$rebinds <- rebinds
  invisible(NULL)
}

.mr_stop_rebinding <- function() {
  .mr_state$rebinds <- NULL
  invisible(NULL)
}

.mr_rebound_hash <- function(name) {
  rb <- .mr_state$rebinds
  if (is.null(rb)) return(NULL)
  if (!(name %in% names(rb))) return(NULL)
  rb[[name]]
}

.mr_resolve_rebinds <- function(rebind) {
  if (is.null(rebind)) return(list())
  if (!is.list(rebind) || is.null(names(rebind)) || any(!nzchar(names(rebind)))) {
    stop("launch(): `rebind` must be a named list.", call. = FALSE)
  }
  for (nm in names(rebind)) .mr_validate_name(nm, context = "launch(rebind=)")

  con <- .mr_get_connection()
  resolved <- list()

  # Suppress interactive tracking for inline stows so launch-setup
  # stows don't pollute the interactive-writer warning path.
  .mr_state$suppress_interactive <- TRUE
  on.exit(.mr_state$suppress_interactive <- NULL, add = TRUE)

  for (nm in names(rebind)) {
    value <- rebind[[nm]]
    resolved[[nm]] <- .mr_resolve_rebind_entry(con, nm, value)
  }
  resolved
}

.mr_resolve_rebind_entry <- function(con, name, value) {
  if (.mr_is_ref(value)) {
    switch(value$kind,
      hash    = .mr_resolve_ref_hash(con, name, value$value),
      run     = .mr_resolve_ref_run(con, name, value$value),
      as_of   = .mr_resolve_ref_as_of(con, name, value$value),
      variant = stop(
        "launch(rebind=): mr_variant() resolution is not yet implemented ",
        "(scheduled for Slice C of the swappability plan).",
        call. = FALSE
      ),
      stop(sprintf("launch(rebind=): unknown reference kind '%s'.", value$kind),
           call. = FALSE)
    )
  } else {
    # Bare R value -> stow through the normal pathway.
    if (is.data.frame(value)) {
      .mr_guard_namespace(name, "table")
      .mr_stow_table(name, value)
    } else {
      .mr_guard_namespace(name, "artifact")
      .mr_stow_artifact(name, value)
    }
  }
}

.mr_resolve_ref_hash <- function(con, name, hash) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND content_hash = ?",
    params = list(name, hash)
  )
  if (nrow(row) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_hash('%s') is not a known content_hash for '%s'.",
      hash, name
    ), call. = FALSE)
  }
  hash
}

.mr_resolve_ref_run <- function(con, name, run_id) {
  run <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE run_id = ?",
    params = list(run_id)
  )
  if (nrow(run) == 0L || is.na(run$outputs[1])) {
    stop(sprintf(
      "launch(rebind=): mr_run('%s') is not a known run id.", run_id
    ), call. = FALSE)
  }
  pairs <- tryCatch(
    jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE),
    error = function(e) list()
  )
  for (p in pairs) {
    if (identical(p$name, name)) return(p$hash)
  }
  stop(sprintf(
    "launch(rebind=): run '%s' did not produce output '%s'.",
    run_id, name
  ), call. = FALSE)
}

.mr_resolve_ref_as_of <- function(con, name, time) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT content_hash FROM _mr_versions
      WHERE logical_name = ? AND first_seen <= ?
      ORDER BY first_seen DESC LIMIT 1",
    params = list(name, time)
  )
  if (nrow(row) == 0L) {
    stop(sprintf(
      "launch(rebind=): mr_as_of() found no '%s' version at or before %s.",
      name, format(time)
    ), call. = FALSE)
  }
  row$content_hash[1]
}
```

- [ ] **Step 6: Update `R/launch.R` signature and wiring**

In `R/launch.R`, replace the `launch()` function's roxygen block and body header with:

```r
#' Launch an R script as a tracked modelrunnR step
#'
#' `launch()` is the tracked-execution entry point. It sources
#' `script_path` inside an instrumented context that watches for
#' `grab()` and `stow()` calls, measures wall-clock duration, and
#' writes a run record to `_mr_runs` whether the script succeeds
#' or errors.
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
#' @param ... Reserved for future arguments and for catching the
#'   removed `pin`/`data` arguments with a clear error message.
#'
#' @return The run record (one row of `_mr_runs`), invisibly.
#' @export
launch <- function(script_path, rebind = NULL, external_inputs = NULL, ...) {
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
  # … (rest of function body unchanged below this point)
```

Then replace all three references to the old pin/data machinery in the body:

| old | new |
|---|---|
| `.mr_resolve_pins(pin, data)` | `.mr_resolve_rebinds(rebind)` |
| `resolved_pins` (local var) | `resolved_rebinds` |
| `.mr_start_pinning(resolved_pins)` | `.mr_start_rebinding(resolved_rebinds)` |
| `.mr_stop_pinning()` | `.mr_stop_rebinding()` |
| `!is.null(.mr_state$pins)` | `!is.null(.mr_state$rebinds)` |

- [ ] **Step 7: Update `R/grab.R` to call the renamed helper**

In `R/grab.R`, find the call to `.mr_pinned_hash(name)` and replace it with `.mr_rebound_hash(name)`.

- [ ] **Step 8: Regenerate NAMESPACE and run the rebind suite**

```bash
Rscript -e 'devtools::document(); devtools::load_all(); devtools::test(filter = "rebind")'
```

Expected: all seven rebind tests pass. `mr_hash`, `mr_run`, `mr_variant`, `mr_as_of`, and the new `rebind` argument are exported and documented.

- [ ] **Step 9: Run the full suite**

```bash
Rscript -e 'devtools::test(); devtools::check()'
```

Expected: all tests pass (including everything that transitively touched `launch()`), R CMD check clean.

If a previously-passing test calls `launch(pin = ...)` or `launch(data = ...)`, migrate it to `rebind = list(...)` in the same commit — the renames are mechanical.

- [ ] **Step 10: Commit**

```bash
git add R/rebind.R R/references.R R/launch.R R/grab.R \
        tests/testthat/test-rebind.R NAMESPACE man/
git commit -m "feat(swappability-B): rename pin/data -> rebind, add mr_*() refs

- R/pin.R renamed to R/rebind.R; internals renamed to match
  (.mr_resolve_rebinds, .mr_start/stop_rebinding, .mr_rebound_hash).
- New R/references.R: mr_hash(), mr_run(), mr_variant(), mr_as_of().
  mr_variant resolution stubbed; wired up in Slice C.
- launch(pin=, data=) hard-errors with a migration message pointing
  at rebind; no backcompat shim, per the swappability design.
- test-pin-data.R -> test-rebind.R, suite rewritten against the
  new surface."
```

---

## Slice C — `label` argument + `grab(variant = …)` + `mr_variant` resolution

**Goal.** Make labels first-class. `launch(script, label = "eta_0.01")` records the label on the run row, `grab("name", variant = "eta_0.01")` resolves to the latest hash produced under that label, and `rebind = list(x = mr_variant("eta_0.01"))` works from the launch side. No auto-propagation yet (Slice F).

**Files:**
- Modify: `R/launch.R` — add `label =` parameter, validate, thread into `.mr_write_run_row()`.
- Modify: `R/grab.R` — add `variant =` parameter, resolution logic, "more than one selector" guard.
- Modify: `R/rebind.R` — replace the `mr_variant()` stub with a real resolver.
- Create: `tests/testthat/test-label.R` — the label + grab-by-variant + mr_variant suite.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-label.R`:

```r
test_that("launch(label = 'x') writes variant_label on the run row", {
  new_test_db()

  script <- write_script('stow(data.frame(a = 1), "out")')
  launch(script, label = "eta_0.01")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_equal(row$variant_label, "eta_0.01")
})

test_that("launch(label = '') and whitespace-only labels error", {
  expect_error(launch("x.R", label = ""),    regexp = "label.*empty",   fixed = FALSE)
  expect_error(launch("x.R", label = "   "), regexp = "label.*empty",   fixed = FALSE)
  expect_error(launch("x.R", label = 42),    regexp = "label.*string",  fixed = FALSE)
})

test_that("launch(label = ' trimmed ') strips whitespace", {
  new_test_db()

  script <- write_script('stow(data.frame(a = 1), "out")')
  launch(script, label = "  eta_0.01  ")

  con <- .mr_get_connection()
  row <- DBI::dbGetQuery(con, "SELECT variant_label FROM _mr_runs")
  expect_equal(row$variant_label, "eta_0.01")
})

test_that("grab(name, variant = 'x') resolves to latest hash produced under that label", {
  new_test_db()

  fit <- write_script('stow(data.frame(v = 1:3), "features")')
  launch(fit, label = "slow")

  fit2 <- write_script('stow(data.frame(v = 1:9), "features")')
  launch(fit2, label = "fast")

  expect_equal(nrow(grab("features", variant = "slow")), 3L)
  expect_equal(nrow(grab("features", variant = "fast")), 9L)
})

test_that("grab(variant = 'nonexistent') errors cleanly", {
  new_test_db()

  stow(data.frame(v = 1), "features")
  expect_error(
    grab("features", variant = "nothing"),
    regexp = "no variant.*nothing",
    fixed = FALSE
  )
})

test_that("grab() errors on multiple selectors including variant", {
  new_test_db()

  stow(data.frame(v = 1), "features")
  expect_error(
    grab("features", variant = "x", version = "abc"),
    regexp = "more than one selector",
    fixed = FALSE
  )
})

test_that("rebind = list(x = mr_variant('slow')) resolves to the labeled variant", {
  new_test_db()

  producer <- write_script('stow(data.frame(v = 1:4), "features")')
  launch(producer, label = "slow")

  consumer <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(n = nrow(f)),  "n")'
  ))
  launch(consumer, rebind = list(features = mr_variant("slow")))
  expect_equal(grab("n")$n, 4L)
})
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "label")'
```

Expected: every test fails — `launch()` has no `label` parameter, `grab()` has no `variant` parameter, `mr_variant()` still errors.

- [ ] **Step 3: Add `label` to `launch()`**

In `R/launch.R`, update the signature, add validation, and thread the resolved label through `.mr_write_run_row()`:

```r
launch <- function(script_path, rebind = NULL, label = NULL, external_inputs = NULL, ...) {
  # ... existing dots/pin/data guard unchanged ...

  label <- .mr_validate_label(label)

  # ... existing body through .mr_write_run_row ... call becomes:

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
  # ... rest of function unchanged ...
}

.mr_validate_label <- function(label) {
  if (is.null(label)) return(NA_character_)
  if (!is.character(label) || length(label) != 1L) {
    stop("launch(): `label` must be a single string.", call. = FALSE)
  }
  trimmed <- trimws(label)
  if (!nzchar(trimmed)) {
    stop("launch(): `label` must not be empty or whitespace-only.", call. = FALSE)
  }
  trimmed
}
```

Update `.mr_write_run_row()`'s signature and body to accept and persist `variant_label`:

```r
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
```

Also update the interactive-run-row builder (the one in `R/interactive.R` that `followups.md` flags as drifting — check its column list matches). Interactive rows should pass `variant_label = NA_character_`.

- [ ] **Step 4: Add `variant =` to `grab()`**

In `R/grab.R`, update the signature, the multi-selector guard, and add a resolution branch:

```r
grab <- function(name, source = NULL, version = NULL, from_run = NULL,
                 as_of = NULL, variant = NULL) {
  .mr_validate_name(name, context = "grab()")
  selectors <- c(!is.null(version), !is.null(from_run),
                 !is.null(as_of),   !is.null(variant))
  if (sum(selectors) > 1L) {
    stop("grab(): more than one selector passed; specify at most one of ",
         "`version`, `from_run`, `as_of`, `variant`.",
         call. = FALSE)
  }

  # Rebind override (first priority): if inside a launch and this name
  # was rebound, return the rebound version.
  rebound <- .mr_rebound_hash(name)
  if (!is.null(rebound)) {
    return(.mr_read_by_hash(name, rebound))
  }

  if (!is.null(variant)) {
    return(.mr_grab_by_variant(name, variant))
  }

  # ... existing source/version/from_run/as_of branches unchanged ...
}

.mr_grab_by_variant <- function(name, variant) {
  con  <- .mr_get_connection()
  hash <- .mr_latest_hash_for_variant(con, name, variant)
  if (is.null(hash)) {
    stop(sprintf("grab(): no variant named '%s' has produced '%s'.",
                 variant, name), call. = FALSE)
  }
  .mr_read_by_hash(name, hash)
}

.mr_latest_hash_for_variant <- function(con, name, variant) {
  # Walk _mr_runs for rows with this variant_label, parse outputs
  # JSON, pick the most recent one that produced `name`.
  rows <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs
      WHERE variant_label = ?
      ORDER BY started_at DESC",
    params = list(variant)
  )
  if (nrow(rows) == 0L) return(NULL)
  for (j in seq_len(nrow(rows))) {
    pairs <- tryCatch(
      jsonlite::fromJSON(rows$outputs[j], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) {
      if (identical(p$name, name)) return(p$hash)
    }
  }
  NULL
}
```

`.mr_read_by_hash()` may already exist in `R/grab.R` under a different name; if so, call it directly rather than creating a duplicate. Scan `R/grab.R` before adding.

- [ ] **Step 5: Wire `mr_variant()` resolution in `R/rebind.R`**

In `R/rebind.R`, replace the `variant = stop(...)` branch of `.mr_resolve_rebind_entry()` with:

```r
variant = {
  con <- .mr_get_connection()
  hash <- .mr_latest_hash_for_variant(con, name, value$value)
  if (is.null(hash)) {
    stop(sprintf(
      "launch(rebind=): mr_variant('%s') has not produced '%s'.",
      value$value, name
    ), call. = FALSE)
  }
  hash
},
```

`.mr_latest_hash_for_variant()` is the helper defined in Step 4; it lives in `R/grab.R` and is accessible from `R/rebind.R` because both load into the package namespace.

- [ ] **Step 6: Run the label suite to verify it passes**

```bash
Rscript -e 'devtools::document(); devtools::load_all(); devtools::test(filter = "label")'
```

Expected: all seven tests in `test-label.R` pass.

- [ ] **Step 7: Run the rebind suite to confirm the mr_variant stub is gone**

Remove the "mr_variant constructor exists but errors at resolution time" test from `test-rebind.R` (it was a Slice B placeholder) and replace it with:

```r
test_that("mr_variant() in rebind errors when no run has produced the name under that label", {
  new_test_db()
  stow(data.frame(v = 1), "features")

  script <- write_script('stow(data.frame(a = 1), "out")')
  expect_error(
    launch(script, rebind = list(features = mr_variant("nobody"))),
    regexp = "mr_variant.*nobody",
    fixed = FALSE
  )
})
```

Run:

```bash
Rscript -e 'devtools::test(filter = "rebind|label")'
```

Expected: both files green.

- [ ] **Step 8: Run the full suite and check**

```bash
Rscript -e 'devtools::document(); devtools::test(); devtools::check()'
```

Expected: all tests pass, R CMD check clean.

- [ ] **Step 9: Commit**

```bash
git add R/launch.R R/grab.R R/rebind.R R/interactive.R \
        tests/testthat/test-label.R tests/testthat/test-rebind.R \
        NAMESPACE man/
git commit -m "feat(swappability-C): label arg, grab(variant=), mr_variant resolution

- launch(label = 'x') records variant_label on the run row; empty
  labels rejected, whitespace trimmed.
- grab(name, variant = 'x') resolves to the latest hash produced
  under that label; multi-selector guard extended to include variant.
- mr_variant() in launch(rebind = ...) now wired to the same
  resolver, closing the Slice B stub."
```

---

## Slice D — Inspection: `variants()` and `variants_unexplored()`

**Goal.** Give the user a way to list labeled variants (`variants()`) and see which labeled upstream combinations a script has not yet consumed (`variants_unexplored()`).

**Files:**
- Create: `R/variants.R` — user-facing `variants()` function.
- Create: `R/variants_unexplored.R` — user-facing `variants_unexplored()` function.
- Create: `tests/testthat/test-variants.R` — suite for both.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-variants.R`:

```r
test_that("variants() with no args lists all labels in the system", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "one")
  launch(s, label = "two")
  launch(s)  # plain run, should not appear

  df <- variants()
  expect_setequal(df$label, c("one", "two"))
  expect_true(all(c("script", "label", "first_seen", "last_seen",
                    "n_runs", "latest_run_id") %in% names(df)))
})

test_that("variants(script = ...) filters to one script", {
  new_test_db()

  s1 <- write_script('stow(data.frame(x = 1), "a")')
  s2 <- write_script('stow(data.frame(x = 1), "b")')
  launch(s1, label = "alpha")
  launch(s2, label = "beta")

  df <- variants(script = normalizePath(s1))
  expect_equal(df$label, "alpha")
})

test_that("variants(name = ...) filters to labels that produced that name", {
  new_test_db()

  s1 <- write_script('stow(data.frame(v = 1), "features")')
  s2 <- write_script('stow(data.frame(v = 1),    "other")')
  launch(s1, label = "slow")
  launch(s2, label = "beta")

  df <- variants(name = "features")
  expect_equal(df$label, "slow")
})

test_that("variants() aggregates multiple runs of the same label", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "one")
  launch(s, label = "one")

  df <- variants()
  expect_equal(df$n_runs, 2L)
})

test_that("variants_unexplored(script) lists labeled upstreams not consumed by the script", {
  new_test_db()

  prod <- write_script('stow(data.frame(v = 1:3), "features")')
  launch(prod, label = "slow")
  launch(prod, label = "fast")
  launch(prod, label = "huge")

  cons <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(n = nrow(f)), "n")'
  ))
  launch(cons, rebind = list(features = mr_variant("slow")))

  df <- variants_unexplored(normalizePath(cons))
  expect_true(all(c("logical_name", "upstream_label", "upstream_hash",
                    "last_seen", "used_by_this_script") %in% names(df)))
  used <- df[df$used_by_this_script, , drop = FALSE]
  expect_equal(used$upstream_label, "slow")
  unused <- df[!df$used_by_this_script, , drop = FALSE]
  expect_setequal(unused$upstream_label, c("fast", "huge"))
})
```

- [ ] **Step 2: Run to verify the tests fail**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "variants")'
```

Expected: every test fails — `variants()` and `variants_unexplored()` do not exist.

- [ ] **Step 3: Implement `variants()` in `R/variants.R`**

```r
#' List labeled variants
#'
#' Returns a data frame of labeled variants known to the active
#' modelrunnR database.
#'
#' @param script Optional script path (absolute or relative — the
#'   function normalizes). If supplied, only variants of that script
#'   are returned.
#' @param name Optional logical name. If supplied, only variants
#'   whose runs produced an output under that name are returned.
#' @return A data frame with columns `script`, `label`, `first_seen`,
#'   `last_seen`, `n_runs`, `latest_run_id`.
#' @export
variants <- function(script = NULL, name = NULL) {
  con <- .mr_get_connection()

  sql <- "
    SELECT
      step                AS script,
      variant_label       AS label,
      MIN(started_at)     AS first_seen,
      MAX(started_at)     AS last_seen,
      COUNT(*)            AS n_runs,
      ARG_MAX(run_id, started_at) AS latest_run_id
    FROM _mr_runs
    WHERE variant_label IS NOT NULL
  "
  params <- list()
  if (!is.null(script)) {
    sql <- paste(sql, "AND step = ?")
    params <- c(params, list(normalizePath(script, mustWork = FALSE)))
  }
  sql <- paste(sql, "GROUP BY step, variant_label ORDER BY last_seen DESC")

  df <- DBI::dbGetQuery(con, sql, params = params)

  if (!is.null(name)) {
    df <- df[.mr_variants_produced(con, df, name), , drop = FALSE]
  }
  df
}

.mr_variants_produced <- function(con, df, name) {
  # For each (script, label) row, check whether any run in that group
  # has an `outputs` JSON entry matching `name`. Returns a logical
  # vector aligned to df.
  if (nrow(df) == 0L) return(logical(0))
  keep <- logical(nrow(df))
  for (i in seq_len(nrow(df))) {
    runs <- DBI::dbGetQuery(
      con,
      "SELECT outputs FROM _mr_runs
        WHERE step = ? AND variant_label = ?",
      params = list(df$script[i], df$label[i])
    )
    for (j in seq_len(nrow(runs))) {
      pairs <- tryCatch(
        jsonlite::fromJSON(runs$outputs[j], simplifyVector = FALSE),
        error = function(e) list()
      )
      if (any(vapply(pairs, function(p) identical(p$name, name), logical(1)))) {
        keep[i] <- TRUE
        break
      }
    }
  }
  keep
}
```

- [ ] **Step 4: Implement `variants_unexplored()` in `R/variants_unexplored.R`**

```r
#' Labeled upstream variants not yet consumed by a script
#'
#' For each `grab()` the script has historically made, returns the
#' set of labeled upstream variants that have produced that name and
#' a flag indicating whether any run of this script has consumed
#' that specific upstream hash.
#'
#' @param script Path to the consumer script.
#' @return A data frame with columns `logical_name`, `upstream_label`,
#'   `upstream_hash`, `last_seen`, `used_by_this_script`.
#' @export
variants_unexplored <- function(script) {
  stopifnot(is.character(script), length(script) == 1L, nzchar(script))
  step <- normalizePath(script, mustWork = FALSE)
  con  <- .mr_get_connection()

  # 1. Which logical names does this script grab historically?
  input_rows <- DBI::dbGetQuery(
    con, "SELECT inputs FROM _mr_runs WHERE step = ?", params = list(step)
  )
  input_names <- unique(unlist(lapply(input_rows$inputs, function(js) {
    if (is.na(js) || !nzchar(js)) return(character())
    vapply(jsonlite::fromJSON(js, simplifyVector = FALSE),
           function(p) p$name, character(1))
  })))

  if (length(input_names) == 0L) {
    return(data.frame(
      logical_name = character(), upstream_label = character(),
      upstream_hash = character(), last_seen = as.POSIXct(character()),
      used_by_this_script = logical(),
      stringsAsFactors = FALSE
    ))
  }

  # 2. For each logical name, find labeled upstream hashes that have
  #    been produced for it and when.
  upstreams <- list()
  for (nm in input_names) {
    rows <- DBI::dbGetQuery(
      con,
      "SELECT variant_label, outputs, started_at
         FROM _mr_runs
        WHERE variant_label IS NOT NULL",
      params = list()
    )
    for (j in seq_len(nrow(rows))) {
      pairs <- tryCatch(
        jsonlite::fromJSON(rows$outputs[j], simplifyVector = FALSE),
        error = function(e) list()
      )
      for (p in pairs) {
        if (identical(p$name, nm)) {
          upstreams[[length(upstreams) + 1L]] <- data.frame(
            logical_name   = nm,
            upstream_label = rows$variant_label[j],
            upstream_hash  = p$hash,
            last_seen      = rows$started_at[j],
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }
  if (length(upstreams) == 0L) {
    return(data.frame(
      logical_name = character(), upstream_label = character(),
      upstream_hash = character(), last_seen = as.POSIXct(character()),
      used_by_this_script = logical(),
      stringsAsFactors = FALSE
    ))
  }
  out <- do.call(rbind, upstreams)
  # Dedup by (name, label, hash) and keep latest last_seen.
  ord <- order(out$last_seen, decreasing = TRUE)
  out <- out[ord, , drop = FALSE]
  key <- paste(out$logical_name, out$upstream_label, out$upstream_hash)
  out <- out[!duplicated(key), , drop = FALSE]

  # 3. Mark which upstream hashes this script has consumed.
  used_pairs <- do.call(c, lapply(input_rows$inputs, function(js) {
    if (is.na(js) || !nzchar(js)) return(character())
    vapply(jsonlite::fromJSON(js, simplifyVector = FALSE),
           function(p) paste(p$name, p$hash), character(1))
  }))
  out$used_by_this_script <- paste(out$logical_name, out$upstream_hash) %in% used_pairs

  rownames(out) <- NULL
  out
}
```

- [ ] **Step 5: Run the variants suite**

```bash
Rscript -e 'devtools::document(); devtools::load_all(); devtools::test(filter = "variants")'
```

Expected: all five tests pass.

- [ ] **Step 6: Full suite + check**

```bash
Rscript -e 'devtools::test(); devtools::check()'
```

Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add R/variants.R R/variants_unexplored.R tests/testthat/test-variants.R \
        NAMESPACE man/
git commit -m "feat(swappability-D): variants() + variants_unexplored()

variants() aggregates (script, label) across _mr_runs with optional
filters by script or produced name. variants_unexplored() lists, for
a given consumer script, which labeled upstream variants have
produced each of the names the script grabs, flagging which have
been exercised."
```

---

## Slice E — Label protection in `prune_versions()` + `prune_variants()`

**Goal.** Labels are the user's "keep this" signal: versions produced under a labeled variant become unconditionally protected from `prune_versions()` (only `force = TRUE` can delete them), and `prune_variants(script, label)` provides explicit deletion of whole variants.

**Files:**
- Modify: `R/prune_versions.R` — extend the protection set to include variant-produced hashes.
- Create: `R/prune_variants.R` — new user-facing deletion function.
- Modify: `tests/testthat/test-prune.R` — label-protection cases.
- Create: `tests/testthat/test-prune-variants.R` — prune_variants suite.

- [ ] **Step 1: Write the failing `prune_versions` protection tests**

Append to `tests/testthat/test-prune.R`:

```r
test_that("prune_versions() unconditionally protects labeled-variant versions", {
  new_test_db()

  s <- write_script('stow(data.frame(v = 1:3), "features")')
  launch(s, label = "slow")

  # Write many more plain versions to push the labeled one out of any
  # `keep = N` window.
  for (k in 2:12) {
    s2 <- write_script(sprintf(
      'stow(data.frame(v = 1:%d), "features")', k
    ))
    launch(s2)
  }

  # keep = 1 would normally delete all but the latest plain version.
  prune_versions("features", keep = 1)

  df <- versions("features")
  expect_true(3L %in% vapply(df$content_hash, function(h) {
    con <- .mr_get_connection()
    as.integer(DBI::dbGetQuery(
      con,
      "SELECT COUNT(*) AS n FROM _mr_versions
        WHERE logical_name = 'features' AND content_hash = ?",
      params = list(h)
    )$n)
  }, integer(1)))
})

test_that("prune_versions(force = TRUE) can delete labeled-variant versions", {
  new_test_db()

  s <- write_script('stow(data.frame(v = 1:3), "features")')
  launch(s, label = "slow")

  prune_versions("features", keep_latest = TRUE, force = TRUE)
  # keep_latest=TRUE + force should leave only the single latest row
  expect_equal(nrow(versions("features")), 1L)
})
```

- [ ] **Step 2: Write the failing `prune_variants` tests**

Create `tests/testthat/test-prune-variants.R`:

```r
test_that("prune_variants(script, label) deletes matching _mr_runs rows", {
  new_test_db()

  s <- write_script('stow(data.frame(v = 1), "features")')
  launch(s, label = "slow")
  launch(s, label = "slow")
  launch(s, label = "fast")

  prune_variants(normalizePath(s), "slow")

  con <- .mr_get_connection()
  remaining <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE variant_label IS NOT NULL"
  )
  expect_equal(remaining$variant_label, "fast")
})

test_that("prune_variants(dry_run = TRUE) does not delete", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "keepme")

  prune_variants(normalizePath(s), "keepme", dry_run = TRUE)

  con <- .mr_get_connection()
  n <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs
                              WHERE variant_label = 'keepme'")$n
  expect_equal(as.integer(n), 1L)
})

test_that("prune_variants requires both script and label", {
  expect_error(prune_variants("x.R"), regexp = "label",  fixed = FALSE)
  expect_error(prune_variants(label = "x"), regexp = "script", fixed = FALSE)
})

test_that("prune_variants leaves downstream labeled variants alone", {
  new_test_db()

  prod <- write_script('stow(data.frame(v = 1:4), "features")')
  launch(prod, label = "slow")

  cons <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(n = nrow(f)), "n")'
  ))
  launch(cons, rebind = list(features = mr_variant("slow")), label = "down")

  prune_variants(normalizePath(prod), "slow")

  con <- .mr_get_connection()
  remaining <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE variant_label IS NOT NULL"
  )
  expect_equal(remaining$variant_label, "down")
})
```

- [ ] **Step 3: Run to verify both suites fail**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "prune")'
```

Expected: all the new tests fail.

- [ ] **Step 4: Extend label protection in `R/prune_versions.R`**

Find `.mr_protected_version_hashes()` (or whatever the current helper is called — see `followups.md` for the exact file:line anchor) and extend it to also add hashes whose producing run has a non-null `variant_label`, with a new gate on `force`:

```r
.mr_protected_version_hashes <- function(con, force = FALSE) {
  # force = TRUE bypasses BOTH recent-runs and label protection in one
  # shot, matching the prose contract below ("force=TRUE overrides both
  # the recent-runs and the variant protection").
  if (isTRUE(force)) return(character(0))

  protected <- .mr_protected_by_recent_runs(con)  # existing helper

  # Additional unconditional protection for labeled-variant outputs.
  label_rows <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE variant_label IS NOT NULL"
  )
  for (j in seq_len(nrow(label_rows))) {
    pairs <- tryCatch(
      jsonlite::fromJSON(label_rows$outputs[j], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) {
      protected <- unique(c(protected, paste(p$name, p$hash)))
    }
  }
  protected
}
```

This assumes the existing protection helper returns `(name, hash)` pairs as "name|hash" strings (per the `followups.md` entry). Match the existing encoding; don't change it.

Thread `force` from `prune_versions()` into this helper and flip the comparison so that `force = TRUE` bypasses both the recent-runs *and* the variant protection in one shot.

- [ ] **Step 5: Implement `prune_variants()` in `R/prune_variants.R`**

Create a new `R/prune_variants.R` (sibling to the existing `R/prune_versions.R`, even though the naming is close — the two functions are user-facing and deserve their own files per convention):

```r
#' Delete a labeled variant
#'
#' Removes all `_mr_runs` rows for `script` whose `variant_label`
#' matches `label`. Versions the deleted runs produced fall back
#' under the normal "referenced by recent runs" protection — if a
#' downstream plain run consumed one of them, it stays; otherwise,
#' the next `prune_versions()` call is free to collect it.
#'
#' Downstream labeled variants are left alone. Tearing down a whole
#' labeled pipeline requires calling `prune_variants()` at each
#' level.
#'
#' @param script Path to the script whose variant should be removed.
#' @param label The variant label to delete.
#' @param dry_run If `TRUE`, print the summary without deleting.
#' @return The summary (`n_runs`, `run_ids`) invisibly.
#' @export
prune_variants <- function(script, label, dry_run = FALSE) {
  if (missing(script)) stop("prune_variants(): `script` is required.", call. = FALSE)
  if (missing(label))  stop("prune_variants(): `label` is required.",  call. = FALSE)
  stopifnot(is.character(script), length(script) == 1L, nzchar(script))
  stopifnot(is.character(label),  length(label)  == 1L, nzchar(label))
  step <- normalizePath(script, mustWork = FALSE)

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con,
    "SELECT run_id, started_at FROM _mr_runs
      WHERE step = ? AND variant_label = ?
      ORDER BY started_at DESC",
    params = list(step, label)
  )

  summary <- list(
    script  = step,
    label   = label,
    n_runs  = nrow(rows),
    run_ids = rows$run_id
  )

  message(sprintf(
    "prune_variants: %d run(s) matching step='%s' label='%s'%s",
    summary$n_runs, basename(step), label,
    if (dry_run) " (dry run)" else ""
  ))

  if (!dry_run && summary$n_runs > 0L) {
    .mr_execute(
      con,
      "DELETE FROM _mr_runs WHERE step = ? AND variant_label = ?",
      params = list(step, label)
    )
  }

  invisible(summary)
}
```

- [ ] **Step 6: Run both prune suites**

```bash
Rscript -e 'devtools::document(); devtools::load_all(); devtools::test(filter = "prune")'
```

Expected: all tests in `test-prune.R` and `test-prune-variants.R` pass.

- [ ] **Step 7: Full suite + check**

```bash
Rscript -e 'devtools::test(); devtools::check()'
```

Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add R/prune_versions.R R/prune_variants.R \
        tests/testthat/test-prune.R tests/testthat/test-prune-variants.R \
        NAMESPACE man/
git commit -m "feat(swappability-E): label protection + prune_variants()

- prune_versions() now unconditionally protects versions whose
  producing run has a non-null variant_label; force=TRUE still
  overrides both recent-run and variant protection in one shot.
- prune_variants(script, label, dry_run=FALSE) deletes matching
  _mr_runs rows. No cascade: versions fall back under the normal
  'referenced by recent runs' protection; downstream labeled
  variants are left alone."
```

---

## Slice F — Auto-propagation of labels from labeled upstreams

**Goal.** When `launch(script)` is called without an explicit `label`, inspect the resolved input hashes of the grabs observed during the run. If all labeled upstreams agree on one label, inherit it. If they disagree, remain plain and emit a disambiguation warning. This is the one slice that touches the launch path in a semantically interesting way.

**Files:**
- Create: `R/propagation.R` — auto-propagation logic.
- Modify: `R/launch.R` — call the propagation helper after the script runs, before writing the run row.
- Create: `tests/testthat/test-propagation.R` — the auto-propagation suite.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-propagation.R`:

```r
test_that("downstream inherits a single agreeing upstream label", {
  new_test_db()

  prod <- write_script('stow(data.frame(coef = 0.1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'm <- grab("model")',
    'stow(data.frame(p = m$coef), "preds")'
  ))
  launch(cons)  # no explicit label

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step LIKE ? ORDER BY started_at",
    params = list(paste0("%", basename(cons)))
  )
  expect_equal(rows$variant_label, "eta_0.01")
})

test_that("downstream stays plain when upstreams disagree and warns", {
  new_test_db()

  prod_m <- write_script('stow(data.frame(a = 1),    "model")')
  prod_f <- write_script('stow(data.frame(v = 1), "features")')
  launch(prod_m, label = "eta_0.01")
  launch(prod_f, label = "fast_features")

  cons <- write_script(c(
    'grab("model"); grab("features")',
    'stow(data.frame(a = 1), "out")'
  ))
  expect_warning(launch(cons), regexp = "ambiguous upstream variants")

  con <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step LIKE ? ORDER BY started_at",
    params = list(paste0("%", basename(cons)))
  )
  expect_true(is.na(rows$variant_label))
})

test_that("explicit label wins over propagation without warning", {
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'grab("model")',
    'stow(data.frame(a = 1), "out")'
  ))
  expect_silent({
    launch(cons, label = "explicit_override")
  })

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step LIKE ? ORDER BY started_at",
    params = list(paste0("%", basename(cons)))
  )
  expect_equal(rows$variant_label, "explicit_override")
})

test_that("no labeled upstreams -> plain run, no warning", {
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod)  # plain

  cons <- write_script(c(
    'grab("model")',
    'stow(data.frame(a = 1), "out")'
  ))
  expect_silent(launch(cons))

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step LIKE ? ORDER BY started_at",
    params = list(paste0("%", basename(cons)))
  )
  expect_true(is.na(rows$variant_label))
})
```

- [ ] **Step 2: Run to verify the tests fail**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "propagation")'
```

Expected: four failures — propagation is not wired in.

- [ ] **Step 3: Implement `R/propagation.R`**

```r
## Auto-propagation of variant labels from upstream grabs.
##
## Called from launch() after source() returns, given the observed
## input pairs of the finished run. Returns one of:
##   - a single label string: downstream inherits it
##   - NA_character_: downstream is plain, no disagreement
##   - structure(NA_character_, disagreement = list(...)): plain +
##     the caller should emit an ambiguous-upstreams warning
##
## The disagreement structure names the names that resolved to
## distinct labels so the warning message can surface them.

.mr_propagate_label <- function(con, inputs) {
  if (length(inputs) == 0L) return(NA_character_)

  # For each observed input {name, hash}, look up the producing run's
  # variant_label via _mr_runs.outputs.
  labels_by_name <- list()
  for (p in inputs) {
    label <- .mr_label_for_produced_hash(con, p$name, p$hash)
    if (!is.null(label) && !is.na(label)) {
      labels_by_name[[p$name]] <- label
    }
  }

  if (length(labels_by_name) == 0L) return(NA_character_)
  uniq <- unique(unlist(labels_by_name))
  if (length(uniq) == 1L) return(uniq)

  structure(NA_character_, disagreement = labels_by_name)
}

.mr_label_for_produced_hash <- function(con, name, hash) {
  # Find the most recent run that produced (name, hash) and return
  # its variant_label. NULL if no producing run or NA label.
  rows <- DBI::dbGetQuery(
    con,
    "SELECT variant_label, outputs FROM _mr_runs
      WHERE variant_label IS NOT NULL
      ORDER BY started_at DESC"
  )
  for (j in seq_len(nrow(rows))) {
    pairs <- tryCatch(
      jsonlite::fromJSON(rows$outputs[j], simplifyVector = FALSE),
      error = function(e) list()
    )
    for (p in pairs) {
      if (identical(p$name, name) && identical(p$hash, hash)) {
        return(rows$variant_label[j])
      }
    }
  }
  NA_character_
}
```

- [ ] **Step 4: Wire propagation into `launch()`**

In `R/launch.R`, after `.mr_warn_interactive_inputs(...)` and before the `.mr_write_run_row(...)` call, add:

```r
# Auto-propagation: if the user didn't pass label= explicitly,
# inspect the observed inputs for labeled upstreams and inherit if
# all agree.
propagation_source <- NULL
if (is.na(label)) {
  prop <- .mr_propagate_label(.mr_get_connection(), rec$inputs)
  if (!is.na(prop)) {
    label <- unclass(prop)
    propagation_source <- paste(names(prop), collapse = ", ")
    if (is.null(propagation_source)) {
      # Single-upstream inheritance: use the first input name as the source.
      propagation_source <- .mr_first_input_producing(rec$inputs,
                                                      .mr_get_connection(),
                                                      label)
    }
  } else if (!is.null(attr(prop, "disagreement"))) {
    disagreement <- attr(prop, "disagreement")
    warning(sprintf(
      "ambiguous upstream variants: %s. Running without a label; pass label= to disambiguate.",
      paste(sprintf("%s -> %s", names(disagreement), unlist(disagreement)),
            collapse = ", ")
    ), call. = FALSE)
  }
}

.mr_first_input_producing <- function(inputs, con, target_label) {
  for (p in inputs) {
    if (identical(.mr_label_for_produced_hash(con, p$name, p$hash), target_label)) {
      return(p$name)
    }
  }
  NA_character_
}
```

Thread the resolved `label` into `.mr_write_run_row(..., variant_label = label)` (already wired from Slice C), and — if `propagation_source` is non-NULL — plumb it into the launch-summary printer so Slice G can show it. For now, stash it on a local variable and pass to a printer helper you'll extend in Slice G; keep this slice focused on the propagation logic itself.

- [ ] **Step 5: Run the propagation suite**

```bash
Rscript -e 'devtools::document(); devtools::load_all(); devtools::test(filter = "propagation")'
```

Expected: all four tests pass.

- [ ] **Step 6: Full suite + check**

```bash
Rscript -e 'devtools::test(); devtools::check()'
```

Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add R/propagation.R R/launch.R tests/testthat/test-propagation.R \
        NAMESPACE man/
git commit -m "feat(swappability-F): auto-propagate labels from agreeing upstreams

A plain launch() inspects the observed inputs of the finished run,
looks up each input hash's producing run's variant_label, and
inherits when all labeled upstreams agree. Disagreement emits an
ambiguous-upstream warning and the run stays plain. Explicit label=
still wins and suppresses the check."
```

---

## Slice G — Per-variant staleness + launch-time summary extras

**Goal.** Staleness is evaluated per `(step, variant_label)` when a variant is in play (explicit `label=` only — auto-propagation labels aren't known at launch start, and the advisory check runs before `source()`). The launch summary always shows grab/stow counts, and appends a variant line when `variant_label` is non-null.

**Files:**
- Modify: `R/staleness.R` — `.mr_is_stale(step, variant_label = NULL)` key extension.
- Modify: `R/launch.R` — pass explicit label to staleness check; extend printer with grab/stow counts and variant line.
- Modify: `R/recording.R` (or wherever grab/stow counts would be computed) — expose counts from the recording context.
- Modify: `tests/testthat/test-staleness.R` — per-variant cases.
- Create: `tests/testthat/test-launch-summary.R` — summary format tests.

- [ ] **Step 1: Write the failing per-variant staleness tests**

Append to `tests/testthat/test-staleness.R`:

```r
test_that("per-variant staleness: two labels get independent histories", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "alpha")
  launch(s, label = "beta")

  # Both are now "fresh" against their own histories.
  expect_match(
    capture.output(launch(s, label = "alpha"), type = "message") |> paste(collapse = "\n"),
    "fresh"
  )
  expect_match(
    capture.output(launch(s, label = "beta"), type = "message") |> paste(collapse = "\n"),
    "fresh"
  )
})

test_that("editing the script invalidates all variants via code_hash", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "alpha")

  writeLines(c('x <- 1', 'stow(data.frame(a = 1), "out")'), s)

  out <- capture.output(launch(s, label = "alpha"), type = "message") |>
         paste(collapse = "\n")
  expect_match(out, "stale")
  expect_match(out, "code")
})
```

- [ ] **Step 2: Write the failing launch-summary tests**

Create `tests/testthat/test-launch-summary.R`:

```r
test_that("launch summary always includes (grabs, stows) counts", {
  new_test_db()

  s <- write_script(c(
    'stow(data.frame(x = 1), "a")',
    'stow(data.frame(x = 2), "b")'
  ))
  out <- capture.output(launch(s), type = "message") |> paste(collapse = "\n")
  expect_match(out, "0 grabs")
  expect_match(out, "2 stows")
})

test_that("launch summary appends a variant line when labeled explicitly", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  out <- capture.output(launch(s, label = "eta_0.01"), type = "message") |>
         paste(collapse = "\n")
  expect_match(out, "variant: eta_0.01")
})

test_that("launch summary notes inherited variant source", {
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'grab("model")',
    'stow(data.frame(a = 1), "out")'
  ))
  out <- capture.output(launch(cons), type = "message") |> paste(collapse = "\n")
  expect_match(out, "variant: eta_0.01")
  expect_match(out, "inherited from")
})
```

- [ ] **Step 3: Run to verify the tests fail**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "staleness|launch-summary")'
```

Expected: all new tests fail.

- [ ] **Step 4: Extend `.mr_is_stale()` to accept a variant_label key**

In `R/staleness.R`, add a `variant_label` parameter and change the "most recent run for this step" query to key on `(step, variant_label)` when the label is non-NA:

```r
.mr_is_stale <- function(step, variant_label = NA_character_) {
  con <- .mr_get_connection()
  if (!is.na(variant_label)) {
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_runs
        WHERE step = ? AND variant_label = ?
        ORDER BY started_at DESC LIMIT 1",
      params = list(step, variant_label)
    )
  } else {
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_runs
        WHERE step = ?
        ORDER BY started_at DESC LIMIT 1",
      params = list(step)
    )
  }
  # ... existing logic over `row` unchanged ...
}
```

Do not widen this to auto-propagation — the advisory check runs before `source()`, so inherited labels are not yet known. Only explicit `label=` influences which history is consulted.

- [ ] **Step 5: Pass explicit label into the staleness call from `launch()`**

In `R/launch.R`, the line:

```r
staleness <- .mr_is_stale(step)
```

becomes:

```r
staleness <- .mr_is_stale(step, variant_label = label)
```

At this point `label` has already been validated and trimmed (Slice C) but auto-propagation has not yet happened (that's post-source), so `label` is either the user's explicit value or `NA_character_`. That matches the design's rule.

- [ ] **Step 6: Extend the recording context to report grab/stow counts**

In `R/recording.R` (or wherever `.mr_start_recording()`/`.mr_stop_recording()` live), make sure the returned record includes counts. If the existing record shape is `list(inputs = ..., outputs = ...)`, extend it to `list(inputs = ..., outputs = ..., n_grabs = ..., n_stows = ...)`. Count every `grab()` call observed (not just distinct names) and every `stow()` call observed.

The minimal change: in whichever internal helpers already append to `inputs` and `outputs`, bump corresponding counters kept in `.mr_state$recording`.

- [ ] **Step 7: Extend `.mr_print_timing_summary()` in `R/launch.R`**

Replace the existing printer with a richer version that consumes the new fields:

```r
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
```

Update the call site in `launch()` to pass the new fields:

```r
.mr_print_timing_summary(
  step,
  duration_ms,
  status,
  n_grabs            = rec$n_grabs,
  n_stows            = rec$n_stows,
  variant_label      = label,
  propagation_source = propagation_source
)
```

- [ ] **Step 8: Run both new suites**

```bash
Rscript -e 'devtools::document(); devtools::load_all(); devtools::test(filter = "staleness|launch-summary")'
```

Expected: the five new tests pass and existing staleness tests still pass.

- [ ] **Step 9: Full suite + check**

```bash
Rscript -e 'devtools::test(); devtools::check()'
```

Expected: clean.

- [ ] **Step 10: Commit**

```bash
git add R/staleness.R R/launch.R R/recording.R \
        tests/testthat/test-staleness.R tests/testthat/test-launch-summary.R
git commit -m "feat(swappability-G): per-variant staleness + richer launch summary

- .mr_is_stale() keys on (step, variant_label) when label is
  explicit; auto-propagated labels still consult plain history
  because the advisory check runs before source().
- Recording context tracks n_grabs / n_stows counts.
- Launch summary always shows (N grabs, N stows); appends a
  'variant: X' line when variant_label is set, annotated with
  '(inherited from Y)' when the label came from auto-propagation."
```

---

## Post-merge cleanup

After Slice G ships and the full suite is green:

- [ ] **Step 1: Update `README.md`** — the user-facing examples currently reference `pin`/`data`. Rewrite the sweep example with `rebind`/`label` and mention the reference constructors. One coherent commit, no behavior changes.

- [ ] **Step 2: Sweep `docs/followups.md`** — the entries flagged as followups that have now been touched by the swappability rework may be obsolete or changed; update `file:line` anchors for functions that moved.

- [ ] **Step 3: Merge `feat/swappability` to `main`** — open a PR with the design merge commit (`d938751`) and all seven swappability slice commits. The PR description should point at `docs/design.md` sections "Grabs are articulation points" and "Variants and swappability" as the canonical reference.

---

## Open items surfaced while planning

These will need to be resolved during implementation:

- **Recording-context counter wiring.** The exact location of the recording append points depends on how `.mr_start_recording()` / `.mr_stop_recording()` and the injected `grab`/`stow` shims are currently structured. Slice G Step 6 describes the shape; the implementer should read `R/recording.R` and `R/launch.R`'s `.mr_source_script()` first to decide whether to bump counters at the shim layer or inside `recording.R`.

- **`capture.output(..., type = "message")` vs `expect_message()`.** The launch summary tests in Slice G use `capture.output` for robustness against multi-line `message()` calls. If the existing tests use `expect_message()`, prefer that for consistency; the patterns are equivalent for single-line output.

- **`variants_unexplored()` column types.** The empty-data-frame fallback in Slice D Step 4 hand-constructs columns with specific types. If downstream tests compare types, make sure `last_seen` is `POSIXct` (not `character`) in both the populated and empty branches.
