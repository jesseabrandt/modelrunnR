---
source: R/launch.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/launch.R

## `launch(code, rebind = NULL, label = NULL, external_inputs = NULL, force = FALSE, duckdb_seed = NULL, materialize = FALSE, on_error = "raise", ...)`
_line 117_

Launch a tracked modelrunnR step

`launch()` is the tracked-execution entry point. It runs user code
inside an instrumented context that watches for `grab()` and
`stow()` calls, measures wall-clock duration, and writes a run
record to `_mr_runs` whether the code succeeds or errors.

The code runs in a fresh environment whose parent is `globalenv()`.
`grab` and `stow` are injected directly into that environment so
the tracked code can call them bare without a preceding
`library(modelrunnR)`.

@section Script, inline, and relaunch modes:
`launch()` dispatches on the first argument:
- **Script mode** -- `launch("fit.R")` sources a file.
- **Inline mode** -- `launch({ ... })` evaluates a braced block as
  tracked code, with no script file on disk. Useful for vignettes,
  quick experiments, and one-off tracked runs. The step identifier
  is derived from the deparsed expression's hash
  (`"<inline:<short-hash>>"`), so editing the expression produces a
  new tracked step rather than silently comparing against a prior
  run's history.
- **Relaunch mode** -- `launch(mr_label("baseline"))` looks up the
  most recent run tagged with that label and re-executes its code.
  For inline pipelines the stored snapshot on the run row is used
  directly. For file pipelines the script file is re-sourced from
  disk; if the file is gone, the stored snapshot is used and an
  informational message is emitted. The label is auto-inherited
  onto the new run unless the caller passes an explicit `label`.
- **SQL mode** -- `launch("features.sql")` (file) or
  `launch(mr_sql("..."))` (inline) registers a SQL `SELECT` as a
  tracked step. The body is a bare query (no `CREATE`); modelrunnR
  wraps it as `CREATE OR REPLACE VIEW <physical> AS <body>` by
  default, or `CREATE OR REPLACE TABLE` when `materialize = TRUE`.
  `-- @inputs: name1, name2` and `-- @output: name` headers declare
  which modelrunnR-managed names the SELECT references and what to
  call the result. See [mr_sql()] for the inline form.

@section Shadowed `source()`:
During a tracked launch, `source()` inside the code (and inside
any transitively-sourced helper) is shadowed with a wrapper that
records each sourced file's path + byte hash on the run row.

The wrapper's default for `local` is `TRUE` (resolving to the
caller's frame), whereas `base::source()`'s default is `FALSE`
(which evaluates into `globalenv()`). Scripts that rely on
`source("helper.R")` populating `globalenv()` will instead find
their helpers scoped to the tracked environment. Explicitly
passing `source("helper.R", local = FALSE)` still works.

@param code The code modelrunnR should run. One of:
  - a braced `{ ... }` block (inline R) -- a literal `{ ... }` at
    the call site triggers inline mode.
  - a path to an `.R` script (R file mode).
  - a path to a `.sql` file, or [mr_sql()] (SQL mode).
  - [mr_label()] (relaunch mode -- re-executes the most recent run
    under that label).
@param rebind Optional named list that overrides what each
  `grab()` inside the script resolves to. List values may be bare
  R objects (stowed inline through the normal versioning path) or
  reference constructors ([mr_hash()], [mr_run()], [mr_variant()],
  [mr_as_of()]) that resolve to existing versions without
  round-tripping through R memory.
@param external_inputs Optional named list with fields `files` (a
  character vector of paths) and/or `env` (a character vector of
  environment variable names). Each declared input is hashed and
  recorded on the run row so later staleness checks can detect
  changes. Missing files error *before* the script is sourced.
@param label Optional string marking this run as belonging to a tracked
  variant (labeled experimental thread). Empty / whitespace-only labels
  are rejected; whitespace is trimmed. See *Variants and swappability*
  in docs/design.md for the full semantics.
@param force Logical, default `FALSE`. When `FALSE` and the step is
  fresh (code + inputs + external inputs unchanged since the last run
  under this label), `launch()` skips execution entirely: the block is
  not evaluated, side effects do not fire, and a `_mr_runs` row is
  written with `status = "skipped_fresh"` to preserve provenance.
  `force = TRUE` runs the block regardless. To globally disable
  skip-on-fresh behavior (restore pre-v0.1 advisory-only staleness),
  set `options(modelrunnR.skip_if_fresh = FALSE)`.
@section Batch launches:
Pass `rebind = mr_binds(...)` (or `mr_envelopes(...)`) to fan out
into one launch per envelope. The block runs once per envelope with
that envelope's rebind / `.label`; the call returns a `data.frame`
of one run row per envelope (same shape as the single-launch
return). Errors in any envelope are captured on that envelope's
`_mr_runs` row (`status = "error"`) and the call raises (or warns
if `on_error = "warn"`) at the end with a count summary. Works for
both R-mode and SQL-mode launches.

@param materialize Logical, default `FALSE`. SQL launches only.
  When `TRUE`, the SELECT body is wrapped as `CREATE OR REPLACE
  TABLE` instead of the default `CREATE OR REPLACE VIEW`, and the
  `_mr_versions` row's `content_hash` is computed over row contents
  (same machinery as `stow()`-of-lazy-tbl). Use for expensive
  feature work consumed many times downstream. Ignored for non-SQL
  launches.
@param duckdb_seed Optional numeric seed in `[-1, 1]`. When set,
  modelrunnR calls `SELECT setseed(duckdb_seed)` on the DuckDB
  connection immediately before evaluating the block, so lazy-tbl
  samplers (`dplyr::slice_sample()`, `RANDOM()`, `USING SAMPLE`)
  produce reproducible output across runs with the same seed. The
  value is stored on the run row. Note: this is DuckDB's RNG, not
  R's -- `set.seed()` does not reach DuckDB. The RNG state is not
  restored after the block.
@param on_error `"raise"` (default) or `"warn"`. Batch mode only.
  Controls whether the final call raises or warns when one or more
  envelopes errored. Per-envelope rows are captured on `_mr_runs`
  either way. Passing this argument outside batch mode is an error.
@param ... Reserved for future arguments. Also traps legacy
  arguments: `pin` / `data` from before the swappability rework
  (error), and the deprecated `script_path` alias for `code`
  (deprecation warning).

@return The run record (one row of `_mr_runs`), invisibly.
@export

## `.mr_guard_no_nested_launch()`
_line 332_

## `.mr_new_id(prefix)`
_line 340_

## `.mr_new_run_id()`
_line 346_

## `.mr_new_batch_id()`
_line 347_

## `.mr_source_script(path)`
_line 349_

## `.mr_resolve_relaunch(label)`
_line 372_

## `.mr_eval_inline(expr)`
_line 420_

## `.mr_write_run_row(step, run_id, inputs, outputs, started_at, duration_ms, status, code_hash = NA_character_, external_inputs = list(files = list()`
_line 429_

## `.mr_helpers_to_json(helpers)`
_line 475_

## `.mr_pairs_to_json(pairs)`
_line 484_

## `.mr_print_timing_summary(step, duration_ms, status, n_grabs = 0L, n_stows = 0L, variant_label = NA_character_, propagation_source = NULL)`
_line 489_

## `.mr_print_staleness(step, staleness, will_skip = FALSE)`
_line 509_

## `.mr_record_skipped_fresh(step, run_id, started_at, external_inputs, code_body, label, rebinds = list()`
_line 535_
