# `launch(mr_run(run_id))` — relaunch by run id

**Status:** design, drafted 2026-04-25
**Scope:** Broaden `launch()`'s first-argument reference acceptance from `mr_label()` only to `mr_label()` + `mr_run()`. Resolve a `run_id` against `_mr_runs` to recover the original `step` + `code_body`, then execute via the existing relaunch path. No new exports, no new constructors, no schema changes.
**Depends on:** existing relaunch machinery in `R/launch.R` (`.mr_resolve_relaunch()`), `mr_run()` constructor in `R/references.R`, `_mr_runs.code_body` (already populated by every launch path).

**Non-goals / deferred:** `mr_hash()` / `mr_variant()` / `mr_as_of()` as first-arg references (see §6). Programmatic re-execution by SQL run id is in scope only insofar as `_mr_runs` already records `code_body` for SQL launches; a separate spec would cover any SQL-specific surface.

## Motivation

Today the only way to re-execute a stored pipeline from the DB is `launch(mr_label("..."))`, which resolves to the *most recent* run under that label. There's no way to relaunch a specific historical run by id — useful when:

- comparing the current code's behavior against a specific past run (not just "latest under label X"),
- replaying a run that was never given a label,
- relaunching one envelope from a batch (each envelope's `_mr_runs` row already has its own `run_id` + `code_body`).

`mr_run()` already exists as a reference constructor (used in `rebind = list(...)`); the gap is that `launch()` rejects it as a first argument with `"only mr_label() is accepted as a first argument reference"` (R/launch.R:251–258). Closing the gap is a small change to the dispatch ladder + the resolver.

## Target usage

```r
# Capture the run id from a prior launch
prev <- launch({ ... })   # invisibly returns the run row
prev$run_id
#> "run_20260425_143010123_a4f9b2"

# Re-execute exactly that run's code
launch(mr_run(prev$run_id))

# Or look one up from _mr_runs and replay it
runs <- DBI::dbGetQuery(con, "SELECT * FROM _mr_runs WHERE step = 'fit.R'")
launch(mr_run(runs$run_id[3]))
```

For file-step pipelines the file on disk is re-sourced when present (matching `mr_label()` behavior); for inline pipelines the stored snapshot is executed.

## Behavior

### Resolution

`launch(mr_run(run_id))` resolves to a `(step, code_body, expr)` triple by querying `_mr_runs` directly:

```sql
SELECT step, code_body, variant_label
FROM _mr_runs
WHERE run_id = ?
```

Then:

- **Inline step** (`step` starts with `"<inline:"`): execute the stored `code_body` (parse + eval). Error if `code_body` is `NA` or empty (pre-migration row).
- **File step** (`step` is a path): if the file exists on disk, re-source it (the current file *is* the pipeline); otherwise fall back to the stored `code_body` with an informational message. Error if the file is gone *and* no snapshot is stored.
- **Synthetic non-launch step** (`step` starts with `"<"` but isn't `"<inline:"`, e.g. `"<interactive:...>"`): error. These rows correspond to ambient activity, not a relaunchable pipeline. Mirrors `launch_code()`'s rule (R/launch_code.R:57–62).
- **No row matches `run_id`**: error with `"launch(): no run with run_id '<id>'"`.

This is the same logic as `.mr_resolve_relaunch()` for labels, with the lookup keyed by `run_id` instead of `variant_label`.

### Label inheritance

`mr_label()` today auto-inherits the label onto the new run unless the caller passes an explicit `label`. `mr_run()` mirrors this: if the resolved run row has a non-NA `variant_label`, the new run inherits it (caller can override). Rationale: keeps a labeled thread continuous when relaunching by id within that thread; if the source run was unlabeled, the new run is unlabeled.

### Step identifier

The new run's `step` is the resolved run's `step` (file path or `<inline:hash>`), not anything derived from the `run_id`. Two consequences worth naming:

- Staleness checks for the new run compare against history under `step` (and `variant_label` if set), exactly as if the user had called `launch("fit.R")` or `launch({ ... })` directly. `run_id` is only an addressing mechanism to recover the code; it does not become part of the new run's identity.
- For inline pipelines, the resolved `<inline:hash>` is the hash of the *original* expression. If the stored `code_body` round-trips deterministically through `parse() |> deparse()`, this stays consistent across relaunches; if it doesn't, the snapshot is what runs but the `step` reflects the original hash. (Same caveat as `mr_label()` today; not a regression.)

### Skipped / errored source runs

A `run_id` that points to a `status = "error"` or `status = "skipped_fresh"` row is still resolvable as long as `code_body` is populated, which it is for every launch path (R/launch.R:455 and R/launch.R:563). The relaunch executes that code afresh — its prior status doesn't propagate.

Because relaunching a non-success row is usually a footgun (the user may not realize they're replaying code that never actually completed cleanly, or whose stored snapshot is the source of truth precisely because the original was skipped without running), modelrunnR emits a `warning()` when the resolved row's `status` is anything other than `"success"`. The warning names the source run id and its status, so the user can decide whether to proceed.

The behavior is configurable via `options(modelrunnR.relaunch_nonsuccess = ...)`:

- `"warn"` (default) — emit `warning()` and continue.
- `"error"` — refuse with an error referencing the option to override.
- `"silent"` — proceed without comment. For users who routinely replay errored runs (e.g. debugging) and find the warning noisy.

Invalid values error at validation time with the list of accepted values. Set per-session or in `.Rprofile`. No per-call argument — the principle here is that the *user's* policy on this is stable across calls, not a per-launch decision.

Implementation: validation lives in a small helper alongside `.mr_resolve_relaunch_by_run()`; same helper is reused if we ever extend `mr_label()` to apply the same policy (out of scope for this spec — `mr_label()` already filters to "most recent" without status filtering, which is a separate question).

## Implementation sketch

Two small changes to `R/launch.R`:

1. **Loosen the reference gate** (R/launch.R:251–259):

   ```r
   if (!inline_mode && .mr_is_ref(code)) {
     if (!identical(code$kind, "label") && !identical(code$kind, "run")) {
       stop(sprintf(
         "launch(): only mr_label() and mr_run() are accepted as a first-argument reference; got mr_%s().",
         code$kind
       ), call. = FALSE)
     }
     relaunch_mode <- TRUE
   }
   ```

2. **Branch the resolver** (R/launch.R:268–275):

   ```r
   } else if (relaunch_mode) {
     resolved <- if (identical(code$kind, "run")) {
       .mr_resolve_relaunch_by_run(code$value)
     } else {
       .mr_resolve_relaunch(code$value)  # by label
     }
     step          <- resolved$step
     code_body     <- resolved$code_body
     relaunch_expr <- resolved$expr
     # Auto-inherit label unless caller passed one explicitly.
     if (is.na(label) && !is.null(resolved$label) && !is.na(resolved$label)) {
       label <- resolved$label
     }
   }
   ```

3. **New internal `.mr_resolve_relaunch_by_run(run_id)`** in `R/launch.R`. Mirrors `.mr_resolve_relaunch()` but queries by `run_id` and returns `list(step, code_body, expr, label)` so the caller can apply label inheritance uniformly. Existing `.mr_resolve_relaunch()` gets a `label` field added to its return value (NA → use prior `variant_label`); this is internal so no contract concern.

4. **Doc updates** in `R/launch.R`'s roxygen block: extend the "Relaunch mode" bullet to mention `mr_run()` alongside `mr_label()`, and update `R/references.R`'s `mr_run()` `@rdname` entry to note it's accepted as a first-arg too.

## Tests (`tests/testthat/test-launch.R` or new `test-launch-by-run-id.R`)

- `launch(mr_run(prev$run_id))` for an inline pipeline executes the stored snapshot and produces a new run row with the same `step` (the `<inline:hash>` value).
- `launch(mr_run(prev$run_id))` for a file-step pipeline re-sources the current file when present.
- `launch(mr_run(prev$run_id))` for a file-step pipeline whose file has been deleted falls back to the snapshot and emits a `message()`.
- Label inheritance: relaunching a labeled run produces a new run with the same `variant_label`; explicit `label = "..."` on the relaunch overrides.
- Error: nonexistent `run_id` → `"no run with run_id"`.
- Error: `run_id` whose `step` starts with `"<interactive:"` → refuses with the synthetic-step message.
- Reject other refs: `launch(mr_hash("..."))`, `launch(mr_variant("..."))`, `launch(mr_as_of(...))` still error with the broadened message naming both accepted refs.
- Non-success source-row policy:
  - default (`"warn"`): relaunching a `status = "error"` or `status = "skipped_fresh"` row warns once and proceeds; new run completes normally.
  - `options(modelrunnR.relaunch_nonsuccess = "error")`: same row errors with a message that names the option.
  - `options(modelrunnR.relaunch_nonsuccess = "silent")`: same row proceeds without warning.
  - invalid option value (e.g. `"loud"`) → validation error naming accepted values.
  - Source row with `status = "success"` never warns, regardless of option.

## Why not `mr_hash()` / `mr_variant()` / `mr_as_of()`?

Recorded for posterity (and to make future "should we add this too?" easy to answer):

- **`mr_hash(hash)`** addresses a *version* (a stowed artifact), not a run. Hash → producing run is N:1 in principle (the same content can come from multiple runs), so resolution is ambiguous. Also semantically odd: "launch this output" is one indirection too many.
- **`mr_variant(label)`** is functionally identical to `mr_label()` for the launch-arg slot. Two names for the same operation would be cruft.
- **`mr_as_of(time)`** needs a step or label to scope against; "the run as of time X" alone is ambiguous across the whole `_mr_runs` table. If we ever want this, the natural shape is `launch(mr_label("X"), as_of = ...)` — orthogonal to this spec.

## Invariants

- **Invariant 4 (schema append-only):** unaffected. No schema change.
- **Invariant 5 (exported API):** `launch()`'s signature is unchanged. Its accepted first-arg types are *broadened* (a strict superset of today). Pre-existing callers continue to work; no behavior change for `launch(mr_label(...))`, `launch("file.R")`, `launch({...})`, `launch("file.sql")`, or `launch(mr_sql(...))`. The error message string for "wrong ref kind" changes — captured under "Reject other refs" tests.
- **Invariant 6 (no new Imports):** unaffected.
- **Invariant 1 (final_practicum):** unaffected — broadening only.

## Completion criteria

- All four R/launch.R + references.R edits committed.
- `devtools::document()` clean.
- New tests added and passing.
- `R CMD check` clean.
- Roxygen text in `launch()` and `mr_run()` reflects the new accepted shape.
- `TODO.md` swept for any "relaunch by run id" entries (none expected, but check).
