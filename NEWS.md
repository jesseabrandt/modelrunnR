# modelrunnR 0.0.0.9000

## New features

* **Inline `launch({ ... })`.** `launch()` now dispatches on its first argument: a literal braced expression runs as tracked code with no script file on disk, while a character path continues to behave as before. Step identity is derived from the deparsed expression's hash (`"<inline:<short>>"`), so editing the block creates a new step instead of silently comparing against a prior expression's history. All existing features (rebind, label, external_inputs, staleness, interactive-input warnings) work identically in both modes.
* **`launch_code(run_id)`.** Retrieves the code that produced a run. For inline runs, returns the deparsed expression body stored on the run row; for script runs, returns the file's current contents, with a fallback to the stored snapshot (and an informational message) when the file is gone. `launch_code(run_id, from_db = TRUE)` forces reading the stored snapshot even when the source file is still on disk — useful for auditing what a historical run actually executed, independent of any later edits.
* **Relaunch-by-label: `launch(mr_label("baseline"))`.** A new reference constructor `mr_label()` joins the existing `mr_hash()` / `mr_run()` / `mr_variant()` / `mr_as_of()` family. When passed as `launch()`'s first argument, it looks up the most recent run tagged with that label and re-executes its code: for inline pipelines the stored snapshot on the run row is used directly; for file pipelines the script file is re-sourced from disk (or the stored snapshot is used if the file has been removed, with an informational message). The label auto-inherits onto the new run unless the caller passes an explicit `label` override. Composes with `rebind`, `external_inputs`, and every other existing launch argument.
* **`_mr_runs.code_body`** column added via the existing idempotent migration path. Populated for *every* tracked run: the deparsed expression for `launch({ ... })` and the captured file bytes for `launch("fit.R")`. Run rows are now self-contained — a run is recoverable even after its source file has been deleted. (A short-lived earlier draft called this column `inline_code` and only populated it for inline launches; the migration renames the column and carries forward any existing data.)
* **Getting-started vignette.** New `vignettes/getting-started.Rmd` walks through the REPL workflow (stow, grab, versions) and the inline `launch({ ... })` flow end-to-end on a small simulated dataset.
* **`launch(..., duckdb_seed = x)`.** Numeric seed in `[-1, 1]` applied
  to DuckDB's RNG via `SELECT setseed(x)` before the block runs. Makes
  lazy-tbl sampling (`dplyr::slice_sample()`, `RANDOM()`, `USING
  SAMPLE`) reproducible across runs. The seed value is stored on the
  run row (`_mr_runs.duckdb_seed`). R's `set.seed()` does not reach
  DuckDB's RNG; this is the hook.

* **`mr_con()` exported.** Returns the live DuckDB connection
  modelrunnR is using, so callers can drop to raw SQL for workflows
  `dbplyr` doesn't express cleanly (stratified sampling, custom CV
  constructions).

## Breaking changes

* **`grab()` on a stored table now returns a `dbplyr` lazy `tbl`** rather
  than a materialized `data.frame`. Artifact reads (stowed models,
  lists, vectors) are unchanged.

  * Pipe through `dplyr::collect()` — or `as.data.frame()` /
    `tibble::as_tibble()` — to materialize.
  * Non-`dplyr` consumers that coerce via `as.data.frame()` auto-collect
    transparently (`lm()`, `ggplot2`, most `stats::*`). Base `$col` and
    base `[` subsetting don't work on lazy tbls — use `dplyr::pull()`
    or collect first.
  * See `vignette("lazy-data")` for the full story.

* **`ingest()` return type changed** from invisible `data.frame` to
  invisible lazy `tbl_dbi`. The function now reads CSVs and Parquet
  files server-side via DuckDB's `read_csv_auto` / `read_parquet` and
  never materializes the frame in R. Most callers ignore the return
  value; any that did capture it will need `|> dplyr::collect()`.

* **`stow()` now accepts a `dbplyr` lazy tbl** and realizes it
  server-side via `CREATE TABLE AS`. Previously such a value fell
  through to the artifact path and errored in `qs2` serialization.
  Non-breaking in the sense that no correct code depended on the old
  failure, but worth calling out.

* **`stow()` is now value-first.** The signature is `stow(value, name)` (was `stow(name, value)`), so the primary object — the value being stowed — can flow through a pipe: `df |> stow("predictions")`. Passing a single character argument is detected and errors with a migration hint. All internal call sites, tests, docs, and the vignette have been updated.

* `launch(pin = ..., data = ...)` is now a hard error. The two arguments were unified into a single polymorphic `rebind` argument: bare R values replace `data`, and the new reference constructors `mr_hash()` / `mr_run()` / `mr_variant()` / `mr_as_of()` replace `pin`. The error message points at `docs/design.md` § *Variants and swappability* for the migration. There is no compat shim — modelrunnR has no production users at the time of this change.

## New features

* **Swappability and labeled variants.** `launch()` gains a `label` argument that marks a run as a tracked **variant** — a user-named experimental thread the framework remembers and protects. Three new inspection / management functions:
  * `variants(script = NULL, name = NULL)` lists labeled variants, optionally filtered by script or produced name.
  * `variants_unexplored(script)` reports labeled upstream variants the script has not yet consumed.
  * `prune_variants(script, label, dry_run = FALSE)` deletes a labeled variant's `_mr_runs` rows; downstream labeled variants are left alone (no cascade).
* **Auto-propagation.** `launch()` without an explicit label inspects the observed inputs of the finished run; if all labeled upstreams agree on one label, the downstream run inherits it. Disagreement emits an `ambiguous upstream variants` warning and the run stays plain.
* **`grab(name, variant = "x")`** resolves to the latest hash produced under that labeled variant. Composes with the existing `version` / `from_run` / `as_of` selectors via the multi-selector guard.
* **Label protection in `prune_versions()`.** Versions whose producing run has a non-null `variant_label` are unconditionally protected; only `force = TRUE` can delete them. Force bypasses both recent-runs protection and label protection in one shot.
* **Per-variant staleness.** When `launch()` is called with an explicit `label`, the staleness check consults only runs of that `(script, variant)` pair, so two variants of the same script have independent staleness state.
* **Richer launch summary.** Always shows `(N grabs, N stows)` counts. When the run carries a `variant_label`, appends a `variant: <label>` line annotated with `(inherited from <upstream>)` when the label was auto-propagated.
* **`_mr_runs.variant_label`** column added via the existing idempotent migration path. Pre-existing databases get the column added on next connect with no manual migration.

## Bug fixes

* `prune_versions()` now combines `keep`, `keep_latest`, and `older_than` as a union of prune masks, matching the long-standing docstring. Passing `keep_latest = TRUE` together with `keep` is an error (overlapping intent).
* Nested `launch()` calls are now detected and error rather than silently clobbering the outer launch's recording, helpers, and pins state.
* Env-var external inputs that remain unchanged no longer incorrectly report stale: the previous implementation compared a JSON-roundtripped `NULL` hash (from an unset env var) against a fresh `NA_character_`, which always mismatched.
* `stow()` and `prune_versions()` now wrap physical writes and metadata updates in DuckDB transactions. A crash mid-write can no longer leave orphaned physical tables or stale `_mr_versions` rows.
* `prune_versions()` protection is now keyed on `(logical_name, content_hash)` pairs rather than `content_hash` alone, so two different logical names sharing a hash cannot cross-protect each other.
* `grab(from_run = ...)` no longer crashes when a run row has `NA` or empty `outputs` JSON.
* `grab(as_of = "...")` now parses string arguments as UTC (to match DuckDB's timezone-naive TIMESTAMP columns), so the same string produces the same version regardless of the session's `TZ`.
* Pruning all versions of a logical name now drops the corresponding DuckDB view, eliminating dangling pointers to dropped physical tables.

## New features

* `_mr_versions` now carries a `UNIQUE INDEX` on `(logical_name, content_hash)` as belt-and-suspenders protection against duplicate rows. **Caveat**: on connect, `.mr_migrate_versions()` runs `CREATE UNIQUE INDEX IF NOT EXISTS`, which will error loudly if a pre-existing `.duckdb` happens to contain duplicate `(logical_name, content_hash)` rows (e.g. from hand-editing). In normal single-writer operation this cannot happen, but if it does, resolve by deduplicating the table manually before reopening the DB.
* `stow()` emits a warning when a data frame has non-default row names, since DBI's backend does not persist them.
* Staleness checks now distinguish `code_unknown` (pre-migration runs that predate `code_hash` tracking) from `code` (actual mismatch). **Users upgrading an existing `.duckdb` may see a one-time `code_unknown` advisory** on the next run after upgrade. Subsequent runs record a real `code_hash` and return to reporting `fresh`.

## Documentation

* `R/backend_duckdb.R` comments now document the type-sensitive hashing contract and the ~0.03%-at-100M-rows 64-bit HASH collision caveat.
* `docs/plan.md` Slice 3 section rewritten to describe the actually shipped `STRING_AGG`+`MD5` algorithm, with a note on why the initially sketched `SUM`/`XOR` scheme was rejected (XOR loses multiplicity; SUM wraps).
