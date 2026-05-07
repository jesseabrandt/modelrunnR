# modelrunnR 0.1.0

First tagged release. Pins the API and storage layout that the
working branches have been converging on. Sections below are grouped
roughly by theme; chronologically the bug fixes and queue refinements
landed last.

## Bug fixes

* `launch(rebind = list(name = <bare value>))` no longer shadows the
  real upstream of `name`. Bare-value rebinds still write a
  `_mr_versions` row (so the value is provenance-tracked,
  hash-resolvable, and visible in `versions(name)`), but the row is now
  flagged with a new `is_rebind = TRUE` column and excluded by the
  latest-version resolver. Naked `grab(name)` after a launch with a
  sample rebind returns the canonical upstream version, as expected.
  `versions(name, include_rebinds = FALSE)` filters rebind rows from
  the listing.

## New features

* `queue()` now accepts `mr_label()` and `mr_run()` as first-argument
  references, mirroring `launch()`. This stages a queued row carrying the
  resolved body — useful for batching re-runs of an existing labeled
  pipeline or specific historical run for later parallel execution. The
  only remaining circular case (`queue(mr_run(qid))` against a queued
  source with no rebind) errors with a clear message.
* Internal: `launch()` and `queue()` now share a single first-argument
  dispatcher (`.mr_dispatch_code_arg()`). No user-visible behavior change
  from the refactor.

## Breaking semantic changes

* `stow(df, name)` now appends to a single growing DuckDB table per
  logical name (append-shape: run-indexed append log), stamping each row
  with `_mr_run_id` and `_mr_variant_label`. The prior behavior —
  creating one `_mr_versions` row per stow — remains for non-tabular
  values (versioned-shape artifact). `grab(name)` returns one coherent
  snapshot by default: inside `launch()` it's the current run's rows;
  outside `launch()` it's the latest run that wrote to the name, with
  system columns stripped. Pass `run = "all"` for the full
  cross-run view with `run_id` + `variant_label` exposed. See
  `docs/superpowers/specs/2026-04-22-append-mode-stow-design.md` for
  the design rationale.

## New features

* `launch()` now accepts `mr_run(run_id)` as a first-argument reference,
  re-executing the specific stored run by id (in addition to the existing
  `mr_label()` form). Source row's `variant_label` is auto-inherited.
  Re-executing a non-`"success"` source row emits a `warning()` by
  default; configurable via
  `options(modelrunnR.relaunch_nonsuccess = c("warn","error","silent"))`.
* `grab(name, run = ...)` — scope an append-table read to a specific
  run id, or pass `run = "all"` for the full-history view (every row
  with `run_id` and `variant_label` surfaced).
* **`prune()` replaces `prune_versions()` and `prune_runs()`** as the
  single exported pruner. Works on both storage shapes: the default
  `by = "auto"` dispatches on the name's shape; explicit `by = "version"`
  / `"run"` / `"age"` pin behavior. Invalid combinations (`by = "version"`
  on a append-shape name, etc.) error clearly. `prune_variants()` stays
  separate — variants are a different axis from shape. This honors the
  rev-3 "shapes should be invisible to the user" amendment of the
  append-mode spec.
* **`stow(df, name)` outside `launch()` is supported.** Mints an
  `<interactive:TS>` run row (matching the existing versioned-shape / `ingest()`
  convention) and stamps the appended rows with that run_id. Bare stows
  no longer error; downstream launches that `grab()` the value get the
  same reproducibility warning already emitted for artifact and ingest
  inputs.
* **`versions(name)` works for append-shape names.** Returns one row per
  appended chunk, keyed by its `chunk_hash`, latest-first; each row's
  `produced_by_runs` lists the run_id that wrote that chunk. (versioned-shape
  semantics unchanged.) Amends the original append-mode spec.
* **`mr_hash()` rebinds work on append-shape names.** Resolves against the
  chunk_hashes surfaced by `versions()`, mapping the hash to the
  producing run_id and using the same append-shape run-filter path as
  `mr_run()`. SQL-launch `@inputs` on append-shape names are also supported
  via on-demand filtered views.
* **`queue()` verb: register a run to `_mr_runs` with `status = "queued"`**
  without executing it. Pickup is `launch(mr_run(id))`, which now also
  drains queued rows in place (preserves `run_id`, `step`, `rebinds`,
  `batch_id`, `duckdb_seed`; populates `status`, timing, session-context).
  `code_body` is frozen for inline steps; for file steps it refreshes
  from disk at pickup, with a drift warning if the file changed.
  `queue(external_inputs = ...)` accepts the same shape as
  `launch(external_inputs = ...)` — files are validated and hashed at
  queue time, re-resolved at pickup. Batch staging via
  `rebind = mr_binds(...)` writes N queued rows under one `batch_id`,
  atomically: a per-envelope error rolls back the whole batch.
  Parallelism is composed by the caller (`future`/`furrr`/shell);
  modelrunnR records and resumes, no built-in worker. See `?queue`
  for the full freeze-vs-refresh contract.
* `launch(mr_run(qid), rebind = ...)` and `launch(mr_run(qid),
  external_inputs = ...)` against a queued row warn that the staged
  values win and proceed with pickup. Spawning a new run from a
  queued template with caller bindings is a future feature
  (see `TODO.md`).
* New status value **`"queued"`** joins the existing set
  (`success`, `error`, `skipped_fresh`, `interactive`). No schema
  migration — `_mr_runs` columns are unchanged.
* `launch(mr_run(id))` for a file-step queued row warns when the file
  content has drifted between queue time and pickup. Set
  `options(modelrunnR.relaunch_nonsuccess = "silent")` to suppress
  the related non-success-source warning.
* **`runs()` — tidy accessor for the run log.** Returns the contents
  of `_mr_runs` as an eager tibble — one row per run, all schema
  columns surfaced. Connection is resolved via `getOption("modelrunnR.db")`,
  matching `versions()` / `variants()` / `grab()` (no `con` argument).
  The `code_body` column carries an `mr_code` class so
  `dplyr::pull(code_body)` prints as readable, optionally
  syntax-highlighted code (via `prettycode`); the DuckDB column itself
  stays plain `TEXT`, so `DBI::dbGetQuery()` against `_mr_runs` is
  unaffected. JSON-shaped columns (`inputs`, `outputs`, `external_inputs`,
  `helpers`, `rebinds`, `attached_packages`) are surfaced as plain `chr`;
  parse on demand with `jsonlite::fromJSON()`. See
  `docs/superpowers/specs/2026-04-25-runs-accessor-design.md`.

## Storage

* New metadata table `_mr_append_tables` is created on connect. No
  changes to `_mr_versions` (invariant 4: additive only).

## Deprecations

* **`launch()` first argument renamed from `script_path` to `code`.** The
  argument accepts a braced block, a file path, `mr_label()`, or
  `mr_sql()` — not only a script path, so the name now reflects the
  contract. Callers that passed `script_path = ...` by name continue to
  work with a deprecation warning; positional callers (`launch("fit.R")`)
  are unaffected. The alias will be removed in a future release; migrate
  named calls to `code = ...`.

## New features (batch launches)

* **`launch(rebind = mr_binds(...))` fans out into one run per
  envelope.** A single `launch()` call drives an entire sweep: every
  envelope writes its own `_mr_runs` row, and the call returns a
  data frame of N rows (one per envelope) shaped identically to the
  single-run return.
* **`mr_binds(..., mode = "zip" | "cross", .labels = NULL)`** builds
  the envelope list from named sweep arguments. `zip` pairs values
  element-wise; `cross` takes the Cartesian product. Optional
  `.labels` attaches an explicit run label per envelope (length must
  equal the expanded envelope count).
* **`mr_variants("a", "b", ...)`** convenience constructor — equivalent
  to `list(mr_variant("a"), mr_variant("b"), ...)`. Lets sweeps over
  variant labels read naturally without bare strings being treated as
  literal rebind values.
* **`mr_envelopes(list(...), list(...), ...)`** primitive constructor
  for hand-built batches, useful when envelopes need per-envelope
  `.label` or mixed reference kinds across runs.
* **`launch(..., on_error = "raise" | "warn")`** new argument controls
  whether a batch with any errored runs raises (default) or warns at
  the end. Per-envelope errors are captured on the run row regardless.
  Passing `on_error =` outside batch mode is itself an error -- the
  argument exists to express batch-level intent and silently ignoring
  it would hide drift.
* **SQL batches work out of the box.**
  `launch("features.sql", rebind = mr_binds(panel = mr_variants("v1", "v2")))`
  fans out one view per envelope under the same SQL body, with the
  word-boundary substitution from the launch-SQL spec applied
  per envelope.

## New features (launch SQL)

* **SQL launches are first-class.** `launch("features.sql")` registers
  the file's bare `SELECT` as a versioned DuckDB view tracked
  identically to R-mode runs. Inline equivalent: `launch(mr_sql("..."))`.
  modelrunnR owns the `CREATE OR REPLACE VIEW <physical> AS <body>`
  wrapper; users supply only the query body plus optional declarative
  headers (`-- @inputs: a, b`, `-- @output: name`).
* **`materialize = TRUE`** opts a SQL launch into table mode, wrapping
  the body as `CREATE OR REPLACE TABLE` and hashing by row contents.
  Default is view (cheap to register; rows compute on `grab()`).
* **`mr_sql()` constructor exported.** Inline counterpart to a `.sql`
  file. Inline mode requires a `-- @output: <name>` header (no
  filename to derive from).
* **`kind = "view"`** is a new `_mr_versions` enum value. `grab()`
  routes views through the same lazy-`tbl` path as tables; consumers
  cannot tell them apart at the dplyr layer.
* **Rebind for SQL launches.** `launch("f.sql", rebind = list(x = mr_hash(...)))`
  rewrites occurrences of `x` in the SELECT body to the rebound
  version's physical name (word-boundary substitution; aliases and
  string literals are not substituted).
* **`_mr_runs.rebinds`** new TEXT column populated for every run that
  resolved a `rebind =`. JSON array: per name, the source tag
  (`variant` / `hash` / `run` / `as_of` / `literal`), a human-readable
  value, and the resolved content_hash. Skipped-fresh rows write the
  resolved rebinds too, so a query against `_mr_runs` can answer
  "what would this run have bound to?" without re-running.

## Breaking changes

* **`launch()` now skips fresh runs by default.** When a step's code,
  recorded inputs, and declared external inputs have not changed since
  the most recent run under the same label, `launch()` does not
  evaluate the block; it writes a `_mr_runs` row with
  `status = "skipped_fresh"` and returns. This matches the cache-shaped
  mental model the API already leans on and fixes the case where a
  `launch()`-wrapped expensive external command (e.g. a long Python
  shell-out) would re-run on every call despite reporting "fresh".
  * `launch(..., force = TRUE)` runs the block regardless.
  * `options(modelrunnR.skip_if_fresh = FALSE)` restores the prior
    advisory-only behavior globally.
  * Side effects inside the block (file writes, `system2()`, etc.) do
    not fire on a skip. Users who relied on the advisory-only behavior
    to re-run blocks that change undeclared global state need to either
    pass `force = TRUE` at the call site or declare the changing state
    as an `external_inputs` entry so staleness can see it.

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

* **`is_stale(mr_label("..."))` / `is_stale(mr_variant("..."))`.**
  Public wrapper around the internal staleness check, so callers can
  gate their own logic on whether a re-run would be a no-op without
  entering `launch()`. Returns a logical scalar with a `reasons`
  attribute matching the reason codes shown in the advisory message
  (`"never_run"`, `"code"`, `"input:<name>"`, `"external:<path>"`,
  `"external:env:<NAME>"`). Only `mr_label()` / `mr_variant()` are
  accepted — the other reference constructors address stored content,
  not pipeline identity, and error with a clear message.

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

* `_mr_versions` now carries a `UNIQUE INDEX` on `(logical_name, content_hash)` as belt-and-suspenders protection against duplicate rows. **Caveat**: on connect, `.mr_migrate_versions()` runs `CREATE UNIQUE INDEX IF NOT EXISTS`, which will error loudly if a pre-existing `.duckdb` happens to contain duplicate `(logical_name, content_hash)` rows (e.g. from hand-editing). In normal single-writer operation this cannot happen, but if it does, resolve by deduplicating the table manually before reopening the DB.
* `stow()` emits a warning when a data frame has non-default row names, since DBI's backend does not persist them.
* Staleness checks now distinguish `code_unknown` (pre-migration runs that predate `code_hash` tracking) from `code` (actual mismatch). **Users upgrading an existing `.duckdb` may see a one-time `code_unknown` advisory** on the next run after upgrade. Subsequent runs record a real `code_hash` and return to reporting `fresh`.

## Bug fixes

* `prune_versions()` now combines `keep`, `keep_latest`, and `older_than` as a union of prune masks, matching the long-standing docstring. Passing `keep_latest = TRUE` together with `keep` is an error (overlapping intent).
* Nested `launch()` calls are now detected and error rather than silently clobbering the outer launch's recording, helpers, and pins state.
* Env-var external inputs that remain unchanged no longer incorrectly report stale: the previous implementation compared a JSON-roundtripped `NULL` hash (from an unset env var) against a fresh `NA_character_`, which always mismatched.
* `stow()` and `prune_versions()` now wrap physical writes and metadata updates in DuckDB transactions. A crash mid-write can no longer leave orphaned physical tables or stale `_mr_versions` rows.
* `prune_versions()` protection is now keyed on `(logical_name, content_hash)` pairs rather than `content_hash` alone, so two different logical names sharing a hash cannot cross-protect each other.
* `grab(from_run = ...)` no longer crashes when a run row has `NA` or empty `outputs` JSON.
* `grab(as_of = "...")` now parses string arguments as UTC (to match DuckDB's timezone-naive TIMESTAMP columns), so the same string produces the same version regardless of the session's `TZ`.
* Pruning all versions of a logical name now drops the corresponding DuckDB view, eliminating dangling pointers to dropped physical tables.

## Documentation

* `R/backend_duckdb.R` comments now document the type-sensitive hashing contract and the ~0.03%-at-100M-rows 64-bit HASH collision caveat.
* `docs/plan.md` Slice 3 section rewritten to describe the actually shipped `STRING_AGG`+`MD5` algorithm, with a note on why the initially sketched `SUM`/`XOR` scheme was rejected (XOR loses multiplicity; SUM wraps).
