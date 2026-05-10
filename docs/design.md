# modelrunnR Design

**Status**: v0.1 implementation complete (including the swappability layer). Open questions remain in the *Open questions* section; further revisions documented in `NEWS.md` and `docs/internal/followups.md`.

**Last updated**: 2026-04-09

---

## What modelrunnR is

modelrunnR is a minimal step-runner for iterative model experimentation in R. It provides two primary functions — `grab()` and `stow()` — that replace the CSV reads and writes in an existing R analysis script. When a script is executed through modelrunnR's entry point (`launch()`), the framework observes which values the script grabs and stows, hashes the script contents, and uses that information to track staleness, timing, and run history. All intermediate results live in DuckDB. The user works with normal R scripts, not a pipeline DSL or declarative configuration format.

modelrunnR is inspired by the orchestration layer of [panelmodeler](../../../Practicum_AI_Branch/panelmodeler) — specifically `runner.R`, `harness_*.R`, `model.R`, `model_specs.R`, `new_model_spec.R`, `python_model.R`, and `stack.R` — but deliberately extracts only the step-running concern. It does not include panelmodeler's ingest, feature engineering, reporting, or exploration layers.

## Core design principles

These are the load-bearing commitments. Each is non-negotiable without explicit revision.

### The script is the step; the I/O calls are the declarations

modelrunnR has no `step()` wrapper, no registration function, no pipeline definition file, no DSL. A "step" in modelrunnR is identified by a script file path. Its code is the contents of that file. Its inputs and outputs are observed at runtime by watching calls to `grab()` and `stow()` inside the script. There is no separate declaration layer to maintain alongside the code — the I/O calls are themselves the declarations.

This is the single most important property of the design. Everything else falls out from it.

### Progressive disclosure

The MVP user interacts with modelrunnR through exactly two functions: `grab()` and `stow()`. They do not need to learn anything else to get staleness tracking, timing, and run history. Additional API surface (inspection, forced reruns, cleanup, run metadata queries) is layered on top and only needed when the user wants to *manage* their runs, not just execute them.

A corollary: the adoption path from "existing R script that reads a CSV and fits a model" to "modelrunnR-tracked step" is a two-line change plus an entry-point swap (`source(script)` → `modelrunnR::launch(script)`).

### Grabs are articulation points

Every `grab()` call is a seam where behavior can be swapped at launch time. A script that reads a CSV path literal, a learning-rate literal, and a formula literal has zero articulation points — it produces one thing, one way. The same script rewritten to grab `features`, `params_xgb`, and `target_formula` has three, and the user can now vary any of them independently, track the history of each, and compose variants across them without editing the script.

modelrunnR's job is to make articulation both **cheap** and **valuable**. Cheap: converting a hardcoded literal into a grab is a two-line rewrite. Valuable: each new grab unlocks a new axis of tracking, swapping, and discoverability — a reward for articulation, made visible on every launch via the grab/stow count in the timing summary.

This principle is load-bearing for the parameter-sweep story (see *Variants and swappability* under *MVP architecture*), but it extends further. Feature substitution, "re-run this with yesterday's inputs," and "what if I swapped the regularizer" are all expressions of the same idea — substitution at grab time — and the package surfaces one mechanism (labeled variants) that covers all of them.

### DuckDB-native in v0.1; analytical-SQL-capable in the seams

All intermediate results live in DuckDB. This is not an accident of convenience — it is a deliberate decision driven by the observation that panel data work is far better served by a columnar analytical database than by serialized R objects or flat files.

At the same time, modelrunnR's internal code should route all database interaction through a narrow, DBI-based interface with a small number of primitive operations (table read, table write, existence check, drop, list, SQL execute, plus metadata helpers). These internal operations are distinct from the user-facing `grab`/`stow` API and should not reuse the user-facing function names. Core logic should avoid DuckDB-dialect-specific SQL (`READ_PARQUET`, `SUMMARIZE`, `PIVOT`, `LIST`/`STRUCT` types) and should lean on DBI where portable SQL suffices. DuckDB-specific features needed for v0.1 performance should be isolated in a single backend file (e.g., `R/backend_duckdb.R`).

The long-term vision is that modelrunnR could support other **analytical** SQL backends (MotherDuck, BigQuery, Snowflake, ClickHouse). Transactional databases (Postgres, MySQL, SQLite) are not a design target. The workload is analytical; forcing the abstraction to accommodate OLTP databases would cost a great deal and serve no one.

Documentation should be honest: DuckDB is the recommended and tested backend; other analytical backends may work but are not supported targets for v0.1.

### Built for the first user

modelrunnR is designed for its first user's workflow. There are no speculative features for hypothetical production users, no generalizations motivated by "someone might need this." Features that do not serve the first user's concrete needs are out of scope until a real second user shows up with a real second workflow. This is a deliberate reaction to the panelmodeler experience of accreting ambition into a single package until it loses focus.

### Content-hash staleness, timing-first UX

Staleness detection is based on content hashes (of code and inputs), not on timestamps or filesystem mtimes. This is borrowed directly from the data-engineering tradition but applied at the script-boundary level rather than at arbitrary DAG nodes.

Timing is surfaced as a first-class UX concern. After each run, modelrunnR should show how long each step took, broken down into user code time versus database time where possible. The user should be able to look at timing output and immediately decide which steps are worth caching and which are cheap enough to re-run. This is explicitly different from "cache everything by default" frameworks — modelrunnR presents timing as the primary input to the caching decision, rather than hiding it behind a cache-first assumption.

## Rejected alternatives

These were considered and deliberately not chosen. Documenting them here so future contributors (including future-self) don't relitigate the decision without new information.

### targets

[`targets`](https://books.ropensci.org/targets/) is a mature, well-designed R package for pipeline reproducibility and dependency tracking. It was considered as a backbone for modelrunnR in several forms:

- **Hiding targets behind a modelrunnR runner.** Rejected because wrapping a general-purpose DAG tool to express a specific (simpler) pattern inherits all of targets' failure modes without getting to simplify them away. Error messages leak targets concepts. Users who need targets' power features have no clean escape hatch. The wrapper becomes a targets-compatibility shim.
- **Exposing targets as `tar_target()` factories from modelrunnR.** Rejected because the user is not interested in targets' DAG abstraction and doing it this way would require users to learn targets to use modelrunnR.
- **Using targets directly instead of building modelrunnR.** Considered and rejected because targets' file-based artifact store (serialized R objects in `_targets/objects/`) fights the DuckDB-native commitment. Forcing panel data through that serialization is exactly the impedance mismatch we want to avoid.

The first user's existing bespoke runner (in panelmodeler) works fine aside from one isolated timer bug. Rewriting a working system on top of a new dependency is not justified by the concrete problems the current system has.

### Model specs as step kinds with framework dispatch

Rejected because it recreates the panelmodeler trap. Once modelrunnR is responsible for knowing what a "model spec" is, it becomes responsible for knowing about every modeling library the user might use, every cross-validation strategy, every ensemble method. Each addition is framework code, framework docs, framework dispatch logic. This is how panelmodeler accumulated its scope.

Instead: modelrunnR has zero opinions about what happens inside a step. A model fit is just R code that reads tables, fits something, and writes tables. If the user wants a convenient wrapper that constructs model-fitting steps, they can write one in their own code — it emits a regular modelrunnR-shaped step, and modelrunnR never needs to know "xgboost" exists.

### Pure function steps (`f(inputs) -> outputs`)

Rejected because it forces data to round-trip through R memory on every step, even for transformations that could stay entirely in DuckDB. For panel data at any real scale, this is the performance footgun DuckDB-as-artifact-store was meant to eliminate. The "pure function" abstraction is clean in the abstract and fights the DuckDB commitment in practice. Passing a table reference instead of a data frame preserves performance but sacrifices the purity that made pure functions appealing in the first place.

### Candidate/approval system for new steps

Rejected because it adds a modal gate at exactly the wrong moment in the user's adoption flow. "Your first run created a candidate step — please approve it before continuing" is the kind of ceremony that causes users to abandon the tool. Cleaner alternative: auto-create step records on run, provide a delete-later API (e.g., `forget_step()`) for cleanup. The user is already expressing intent to track by choosing `launch()` over plain `source()` — there is no second approval decision to make.

### Explicit `step()` wrapper

Rejected in favor of "the script is the step." Explicit wrappers add ceremony without adding information — the framework can observe everything a wrapper would declare, and the script file is already a natural boundary for R code. This is closely related to the progressive-disclosure principle: the MVP user shouldn't need to learn a wrapper syntax.

### Separate `pin` and `data` arguments on `launch()`

An earlier draft split rebinding into two arguments: `pin` for specifying existing versions by hash or run ID, and `data` for inlining R values that would be stowed and then pinned. Rejected because users think in terms of intent (*"use this as `features`"*) rather than mechanism (*"reference vs. inline"*). The split created two arguments to remember, forced callers to merge defaults in two places, and made table-shaped parameters awkward — there was no round-trip-free way to say *"use the `features` table produced under the `slow_features` variant"* without hand-resolving hashes via `variants()`. A single polymorphic `rebind` argument, dispatching on whether the value is a bare R object or a reference constructor (`mr_hash()`, `mr_run()`, `mr_variant()`, `mr_as_of()`), collapses this to one concept and composes cleanly with the variant vocabulary — see *Variants and swappability*.

## MVP architecture

This section is specific enough to guide implementation but intentionally leaves details open where the design hasn't converged.

### User-facing API (v0.1)

Ten user-facing functions plus four reference constructors used inside `rebind = list(...)`. Names are considered committed for v0.1 design purposes but may be revised if they feel wrong during implementation.

**Primary functions**:

- **`grab(name, source = NULL, version = NULL, from_run = NULL, as_of = NULL, variant = NULL)`** — retrieve whatever is stowed under `name`. Returns the appropriate R type automatically: a data frame for tables, the original object for artifacts. With no selectors, returns the current latest version. If `source` is given and `name` does not exist, `ingest()` is called under the hood. If `source` is given and `name` exists with a different source hash, `ingest()` is called again and produces a new version (the old version remains queryable — see Versioning below). `version`, `from_run`, `as_of`, and `variant` select specific historical versions — the last of these resolves to the latest `content_hash` produced under a labeled variant (see *Variants and swappability* below). Specifying more than one selector is an error. Outside a tracked launch, behaves as a plain read.

- **`stow(value, name)`** — persist `value` under a logical name. Dispatches on type: data frames (and tibbles, data.tables) are stored as DuckDB tables; all other R objects are stored as artifacts (see Non-table storage below). Inside a tracked launch, the write is recorded as an output. Outside a tracked launch, it's recorded under a synthetic interactive step identifier; see Interactive I/O below.

- **`ingest(name, source)`** — read a flat file (CSV, parquet, etc.) and load it into DuckDB as `name`, recording the source file path and content hash in metadata. Callable explicitly, or implicitly via `grab(name, source = ...)`.

- **`launch(code, rebind = NULL, label = NULL, external_inputs = NULL)`** — entry point for tracked execution. Runs `code` in an instrumented context (a file path, a braced block, a SQL ref, or a relaunch label), records observed I/O, measures wall-clock time, and writes a run record to the metadata table on completion. The `rebind` argument accepts a named list mapping logical names to replacement values, overriding what each `grab()` inside the script resolves to; list values may be bare R objects (stowed inline through the normal versioning path) or reference constructors (`mr_hash()`, `mr_run()`, `mr_variant()`, `mr_as_of()`) that resolve to existing versions without round-tripping through R memory. The `label` argument marks the run as belonging to a tracked variant — a user-named experimental thread that survives code edits, is protected from `prune_versions()`, and is visible in `variants()`. Runs without a label are plain runs. See *Variants and swappability* below for the full semantics of rebinding, labels, and auto-propagation. `external_inputs` allows declaring file paths or env vars that should be tracked as inputs for staleness.

- **`db_path()`** — inspector; returns the currently-active DuckDB file path.

- **`versions(name)`** — list all versions of a logical name. Returns a data frame with content hash, first/last seen timestamps, size, and producing runs.

- **`prune_versions(name = NULL, keep = NULL, keep_latest = FALSE, older_than = NULL, force = FALSE)`** — explicit, user-invoked garbage collection. Policy arguments include `keep = N` (most recent N), `keep_latest = TRUE` (only the current), `older_than = "30d"` (time-based). Versions referenced by recent run records are protected from pruning unless `force = TRUE`. Versions whose producing run has a non-null `variant_label` are **unconditionally protected** — labels are the user's explicit "keep this" signal, and the normal `keep` / `older_than` policies do not apply to them. Only `force = TRUE` can delete labeled-variant versions. Called without `name`, applies to all stored names.

- **`variants(script = NULL, name = NULL)`** — inspection. Returns a data frame listing labeled variants, one row per `(script, label)` pair (so the same label applied to two different scripts produces two rows). Called with neither argument, lists every labeled variant in the system. With `script =`, lists variants of that script. With `name =`, lists variants that have produced outputs under that logical name. Columns: `script`, `label`, `first_seen`, `last_seen`, `n_runs`, `latest_run_id`.

- **`variants_unexplored(script)`** — discoverability. For each grab the script has historically made, returns which labeled upstreams exist and which have been exercised by this script. Columns: `logical_name`, `upstream_label`, `upstream_hash`, `last_seen`, `used_by_this_script`. A user scanning this table sees at a glance which experimental combinations they haven't run downstream yet.

- **`prune_variants(script, label, dry_run = FALSE)`** — deletion of labeled variants. Both `script` and `label` are required (no global "delete all" shortcut). Counts affected runs and prints a summary before executing; `dry_run = TRUE` prints the summary without deleting. The deletion itself removes matching rows from `_mr_runs`; versions produced by those runs fall back under the normal "referenced by recent runs" protection, so downstream plain runs that consumed them keep their inputs resolvable. Downstream *labeled* variants are left alone — tearing down a whole labeled pipeline requires calling `prune_variants()` at each level.

**Reference constructors** — small wrappers used inside `launch(rebind = list(...))` to address existing versions by identity instead of inlining R values. Each returns a tagged list that `launch()` resolves to a content hash before recording starts:

- **`mr_hash(hash)`** — bind to a specific `content_hash`.
- **`mr_run(run_id)`** — bind to whatever output that run produced under this name.
- **`mr_variant(label)`** — bind to the latest hash produced under that labeled variant.
- **`mr_as_of(time)`** — bind to the latest hash as of a point in time.

These mirror the selector arguments on `grab()` (`version`, `from_run`, `variant`, `as_of`) so both launch-time rebinding and in-script grabbing share a single vocabulary for addressing values.

**Configuration** is managed via R `options()`, not setter functions:

- `options(modelrunnR.db = "path/to/custom.duckdb")` — override the default DuckDB location.
- `options(modelrunnR.blob_threshold = n_bytes)` — artifact BLOB-vs-filesystem threshold (default 10 MB).
- `options(modelrunnR.version_warn_threshold = N)` — version-count threshold for gc warnings (default 20).

There is no `connect()` function — the name would collide with `DBI::dbConnect()` idioms, and options-based configuration keeps the API surface smaller.

### Execution flow

When `launch(code, rebind = NULL, label = NULL)` is called:

The canonical flow below assumes file-mode R; inline, relaunch, and SQL modes dispatch through the same recording context with mode-specific variations at steps 1 and 5.

1. Compute the content hash of the script file.
2. Open (or reuse) the DuckDB connection for the current artifact store.
3. Establish a recording context that instruments `grab()` / `stow()` calls made during the source.
4. If `rebind` is non-empty, populate the rebind map: bare R values are stowed through the normal versioning path and their resulting content hashes recorded; `mr_*()` references are resolved to content hashes directly. The rebind map overrides default `grab()` resolution for the duration of the launch.
5. `source()` the script in that context.
6. Resolve the run's `variant_label`: if `label =` was passed, use it; otherwise, if all labeled upstreams among the observed grabs agree on a single label, inherit it and emit a launch-time message; otherwise leave `variant_label` NULL (with a warning if upstreams disagreed).
7. On completion (success or failure), write a run record to the metadata table with: step identifier (script path), code hash, observed inputs, observed outputs, `variant_label`, external inputs, start timestamp, duration, status.
8. Surface timing output to the user. The summary always includes the script path, status, wall-clock duration, and counts of `grab()` and `stow()` calls observed during the run. When `variant_label` is non-null, a variant line is appended naming the label and (if auto-inherited) its upstream source.

Errors during script execution should not prevent the run record from being written — a failed run is still a fact worth recording.

### Versioning and non-destructive writes

Writes to tables and artifacts in modelrunnR are non-destructive by default. Every write is content-addressed, deduplicated, and preserved. The user opts into cleanup via explicit garbage collection (`prune_versions()`).

The approach is a **hybrid**: content-addressed physical storage combined with a temporal metadata layer. Physical storage is like a git object store — keyed by the hash of what's inside. The metadata layer adds timestamps, run identifiers, and logical names on top, so users get temporal semantics without losing dedup.

#### Physical layer

When `stow(df, "features")` is called:

1. Compute a stable, row- and column-order-independent content hash of `df`. v0.1 uses `MD5(STRING_AGG(CAST(HASH(sorted_cols) AS VARCHAR), '|' ORDER BY HASH(sorted_cols)))` on a transient DuckDB temp table. The algorithm is type-sensitive (integer vs double of the same values hash differently) and materializes the STRING_AGG in memory; a streaming alternative and a total-order tiebreaker for 100M+ row frames are tracked in `docs/internal/followups.md`.
2. Check whether a physical table `features__<hash>` already exists.
3. **If it exists**: no new physical table is created. This is automatic dedup — running the same script twice with identical output costs nothing in storage. Metadata is updated to record that the current run also produced this hash.
4. **If it doesn't exist**: create `features__<hash>` with the content and insert a metadata row linking the logical name `features`, the hash, the physical table, and the producing run.
5. Create or update a DuckDB view named `features` pointing to the most recent hash.

Artifacts follow the same pattern: serialized bytes are hashed, stored under a hash-keyed name (as a BLOB row or filesystem file depending on size), and the logical name resolves via metadata to the latest hash.

#### Metadata layer

Two tables in the DuckDB file alongside the user's data:

**`_mr_versions`** — one row per distinct (logical name, content hash) pair:

| column | type | meaning |
|---|---|---|
| `logical_name` | TEXT | user-facing name (e.g., `features`) |
| `content_hash` | TEXT | hash of the stored content |
| `physical_name` | TEXT | actual DuckDB table name or filesystem path |
| `kind` | TEXT | `table` or `artifact` |
| `first_seen` | TIMESTAMP | first time this hash was written |
| `last_seen` | TIMESTAMP | most recent time a run produced this hash |
| `size_bytes` | BIGINT | storage footprint (used for gc decisions) |

**`_mr_runs`** — one row per tracked run:

| column | type | meaning |
|---|---|---|
| `step` | TEXT | absolute, normalized script path (from `normalizePath()`) |
| `run_id` | TEXT or BIGINT | unique identifier for this run |
| `code_hash` | TEXT | hash of script + helper files at run time |
| `inputs` | TEXT (JSON) | list of `{name, hash}` pairs for tables read |
| `outputs` | TEXT (JSON) | list of `{name, hash}` pairs for tables and artifacts written |
| `external_inputs` | TEXT (JSON) | declared external inputs (files, env vars) and their hashes |
| `helpers` | TEXT (JSON) | list of `{path, hash}` pairs for files transitively `source()`d by the script |
| `variant_label` | TEXT (nullable) | user-provided or auto-propagated label; NULL for plain runs |
| `started_at` | TIMESTAMP | run start time |
| `duration_ms` | BIGINT | wall-clock duration |
| `status` | TEXT | `success` / `error` / `running` |

The relationship *variant → version* is derived via `_mr_runs.outputs`; no separate `_mr_variants` metadata table is introduced in v0.1 (deferred until labels need lifecycle attributes beyond what fits on a run row).

Temporal semantics come from joining these: "what did run 42 produce for `features`?" → look up `_mr_runs` for run 42, find the `features` hash in its `outputs`, then resolve via `_mr_versions` to the physical table.

Schema uses only portable SQL types so the metadata layer can migrate to other analytical backends without a rewrite.

#### Read API

```r
# Read current latest (the normal case)
grab("features")

# Read a specific version
grab("features", version = "ab3f7...")        # by content hash
grab("features", from_run = "run_42")         # via run metadata
grab("features", as_of = "2026-04-08 14:00")  # as-of-time lookup

# Inspect history
versions("features")
# -> data.frame with columns: content_hash, first_seen, last_seen,
#    size_bytes, produced_by_runs
```

#### Garbage collection

Versioning is non-destructive by design, so disk grows over time. Two mechanisms for cleanup:

**Automatic warning** when a logical table accumulates more than `getOption("modelrunnR.version_warn_threshold", 20)` versions. The warning surfaces on the next write or the next `launch()` call, telling the user to consider running `prune_versions()`. No automatic pruning ever happens.

**Explicit pruning** via `prune_versions()` (see User-facing API above). Policy arguments control what gets kept: `keep = N`, `keep_latest = TRUE`, `older_than = "30d"`. Versions referenced by recent run records (even if not "latest") are protected from pruning unless the user passes `force = TRUE` — this prevents gc from silently breaking `grab(..., from_run = ...)` queries.

#### Cost model

Content hashing adds per-write overhead. For small tables this is negligible; for very large tables (tens of millions of rows) hashing costs non-trivial time. v0.1 ships the materialized `STRING_AGG + MD5` aggregate described above — at ~100M rows the intermediate string is on the order of 2 GB, which is a post-v0.1 optimization target (true streaming aggregate or a commutative chunked accumulator). The shipped algorithm satisfies the load-bearing requirements: stable across row/column order, deterministic, and multiplicity-preserving.

### Connection and project layout

modelrunnR auto-opens a DuckDB connection on first call to any table-facing function. The user never invokes an explicit connection function.

The default DuckDB file path is determined by walking up the filesystem from the current working directory looking for project markers, in order: `DESCRIPTION`, `.Rproj`, `.git/`, `renv.lock`, `.here`. If a project root is found, the default path is `<project_root>/modelrunnR.duckdb`. If no root is found, the default is `<cwd>/modelrunnR.duckdb` and modelrunnR emits a warning suggesting the user add a project marker so the DB location becomes stable across subdirectories.

The user overrides the default via `options(modelrunnR.db = "path")` at any time before the first table-facing call — typically at the top of a script or in `.Rprofile`.

Connection lifecycle: lazy-opened on first use, reused for the rest of the R session, closed via a finalizer on session exit. `db_path()` surfaces the current path for inspection.

The project-root walker should be implemented internally (~20 lines) rather than depending on `here` or `rprojroot`, to keep Imports lean.

### Non-table storage

When `stow()` is called with a value that isn't a data frame, it's persisted as an artifact rather than a DuckDB table. Artifacts cover fitted model objects, serialized objects from other languages, images, and any other R object the user wants to version alongside their tables. The storage mechanism:

- **Dispatch rule**: `stow()` checks `is.data.frame(value)` (which covers tibbles and data.tables). True → store as a DuckDB table. False → store as an artifact.
- **Serialization**: `qs::qsave()` (fast, compact; adds `qs` to Imports). Chosen over base `serialize()` / `saveRDS()` because it handles R model objects substantially better.
- **Storage location**: objects whose serialized size is below `getOption("modelrunnR.blob_threshold")` (default 10 MB) are stored as a BLOB row in the metadata table inside the DuckDB file. Objects above the threshold are written to `./modelrunnR_artifacts/<name>__<hash>.qs` on the filesystem, with the path recorded in metadata. Small artifacts preserve the "one DuckDB file = entire artifact store" property; large artifacts escape to the filesystem rather than bloating the DB file.
- **Namespace**: artifacts and tables share a single unified namespace. A name cannot refer to both. `stow(model, "features")` errors if `features` already exists as a table, and vice versa. Checked at write time.
- **Retrieval**: `grab("model_xgb")` returns the original R object by deserializing from whichever storage location the metadata points to. The user doesn't need to know whether a given name is a table or an artifact — `grab()` returns whatever was stowed.
- **Tracking**: artifacts appear in a step's `outputs` alongside tables and participate in versioning and staleness detection identically.

### Interactive I/O

`grab()` and `stow()` can be called outside a `launch()` boundary — from the REPL, from a plain `source()`, or from any untracked R code. Behavior:

- **Interactive writes** (`stow()` calls) are recorded with a synthetic step identifier of the form `<interactive:YYYY-MM-DD HH:MM:SS>`. This captures the fact that a name was mutated outside any reproducible script.
- **Interactive reads** (`grab()` calls) are *not* recorded. Reads don't change state, and recording every REPL exploration would clutter the metadata without benefit.
- **Reproducibility warnings**: when a scripted launch's recorded inputs include a name whose most recent write came from an interactive session, modelrunnR warns the user at launch time: *"step `X` grabs `Y`, which was last stowed interactively on [timestamp]. This step is not fully reproducible from source."*

This catches the "I manually patched a table in the REPL and then a script started depending on it" failure mode, which is exactly the kind of non-reproducibility land mine the framework should surface.

### Variants and swappability

modelrunnR has no special concept of "parameters." Parameters are values a script grabs, and a sweep is a loop around `launch()` that varies which value each grab resolves to. This falls out of the versioning system: each iteration binds different inputs, so each produces distinct output versions that coexist automatically.

But sweeps are not a distinct feature. They are one application of a broader principle: **every `grab()` call is a default binding that `launch()` can rebind.** The machinery has two pieces, orthogonal in role.

**Rebinding — the `rebind` argument.** `launch(script, rebind = list(...))` accepts a named list that overrides what each grab in the script resolves to. The list is polymorphic on what you pass:

- A **bare R value** (typically a data frame, but any R object) — stowed into DuckDB, hashed, and bound for the duration of the launch. Ergonomic for config-shaped inputs that naturally live in R memory.
- **`mr_hash("ab3f...")`** — binds to a specific content hash.
- **`mr_run("run_42")`** — binds to whatever output that run produced under this name.
- **`mr_variant("slow_features")`** — binds to the latest hash produced under that labeled variant (see *Identity* below).
- **`mr_as_of("2026-04-08")`** — binds to the latest hash as of a point in time.

These forms are deliberately parallel to the selector arguments on `grab()` itself (`version`, `from_run`, `as_of`, `variant`) so launch-time rebinding and in-script grabbing share a single mental model for addressing values. **Bare R values stow; `mr_*()` references do not** — for large tables that should stay in DuckDB, reach for a reference.

**Identity — the `label` argument.** `launch(script, label = "...")` marks a run as belonging to a tracked **variant**: a user-named experimental thread the framework remembers and protects. Labels are free-text strings (`"eta_0.01"`, `"fast_features"`). A run without a label is a plain run, exactly as today. A run with a label is a variant — addressable via `grab(name, variant = ...)` or `rebind = list(name = mr_variant(...))`, protected from `prune_versions()`, and visible in `variants()`.

The key distinction: **`rebind` delivers values; `label` confers identity.** Passing `rebind =` without `label =` is valid and common — it says "run the script with these values, but I'm not claiming a distinct experimental thread." Casual iteration (edit, run, edit, run) stays plain; only explicit labels mint variants. Labels also span code edits: a comment tweak in `fit_xgb.R` changes `code_hash` but not the label, so tomorrow's `launch("fit_xgb.R", label = "eta_0.01", rebind = ...)` is a new run of the same labeled variant with a fresh `code_hash` recorded for audit.

**Auto-propagation.** When a downstream script launches without an explicit label, modelrunnR inspects the resolved hashes of its grabs. If all labeled upstreams agree on one label, the downstream run inherits it automatically and a launch-time message announces the inheritance:

```
modelrunnR: predict.R [success] in 2,312 ms (3 grabs, 1 stow)
  variant: eta_0.01 (inherited from model_xgb)
```

If upstreams disagree, the run is plain and a warning surfaces the ambiguity:

```
ambiguous upstream variants: model_xgb → eta_0.01, features → fast_features.
Running without a label; pass label= to disambiguate.
```

Propagation only extends labels along paths the user has not contradicted — it never invents new ones — so variant count is bounded by the labels users deliberately created.

**Examples.**

A hyperparameter sweep, using bare values (config-shaped, naturally in R memory):

```r
configs <- list(
  list(label = "eta_0.10", nrounds = 100, eta = 0.10),
  list(label = "eta_0.05", nrounds = 200, eta = 0.05),
  list(label = "eta_0.01", nrounds = 500, eta = 0.01)
)

for (cfg in configs) {
  launch("fit_xgb.R",
    rebind = list(params_xgb = as.data.frame(cfg[c("nrounds", "eta")])),
    label  = cfg$label)
}
```

A feature-set sweep, using variant references (table-shaped, stays in DuckDB):

```r
for (fs in c("slow", "fast", "huge")) {
  launch("fit_xgb.R",
    rebind = list(features = mr_variant(paste0(fs, "_features"))),
    label  = paste0("fit_", fs))
}
```

A subsequent `launch("predict.R")` without an explicit label will grab `model_xgb`, see it came from a labeled variant, and inherit that label. `grab("predictions", variant = "eta_0.01")` then works across days, code edits, and downstream scripts — the label is the durable handle, the hash is the audit trail.

**Explicitly deferred past v0.1:** `rename_variant()` (to fix label typos), `launch_unexplored()` (run the missing combinations reported by `variants_unexplored()`), and an automatic labeled-cascade mode on `prune_variants()`. See *Open questions*.

## Staleness model

A step is **stale** if any of the following hold:

1. Its script file's content hash differs from the most recent recorded run's `code_hash`.
2. Any of its observed inputs have been re-written by an upstream step since this step's most recent run.
3. Any of its declared external inputs (files, env vars) have changed since the most recent run.

A step is **fresh** only if none of the above hold.

**Per-variant staleness.** When a variant is in play, staleness is evaluated *per variant*, not per script. Two runs of `fit_xgb.R` under labels `eta_0.01` and `eta_0.05` each have their own staleness state — edits to the script invalidate both (code hash), but changes to upstream inputs only invalidate the variants that actually grabbed those upstreams. For plain (unlabeled) runs, staleness is evaluated per script as before.

The precise definition of "an input has changed" when the input is a DuckDB table (does the table itself have a hash? is it enough that the upstream step ran again?) is an open question. The likely answer is: track the `run_id` of the upstream step that produced each input, and consider an input changed if a newer upstream run exists.

**Helper files.** When a tracked script `source()`s a helper file, the helper's content contributes to the step's code hash. The instrumentation wraps `source()` during a tracked run to record each loaded file's path and content hash, recursively (with cycle detection). The effective code hash is `hash(script_contents + sorted_helper_hashes)`. Installed packages, base R, and `.Rprofile` are explicitly *not* hashed — use renv/pak for package reproducibility; declare environment variables or external files as external inputs if they matter for your step.

**Branchy scripts.** If a script reads different tables on different runs due to branching logic, the instrumentation records only what actually executed. Staleness for the next run is evaluated against the most recent run's recorded inputs. If a different branch executes on a rerun, the new run gets a new record and staleness proceeds against the new inputs. No branch prediction, no coverage analysis — the metadata is a faithful log of what actually happened.

"Stale" and "fresh" are advisory by default. The framework's job is to *tell* the user which steps are stale, not to silently skip reruns or silently auto-run. The user decides whether to act on staleness information. (This default may be revisited once real usage reveals whether silent skip-if-fresh is desired.)

## Open questions

Decisions deferred to later conversations or to implementation time. Each has a brief status note.

- **Function naming (revisitable).** Current names: `grab`, `stow`, `ingest`, `launch`, `db_path`, `versions`, `prune_versions`, `variants`, `variants_unexplored`, `prune_variants`, plus the `mr_hash` / `mr_run` / `mr_variant` / `mr_as_of` reference constructors. Committed for v0.1 design purposes and to serve as the plan's vocabulary. May be revised if they feel wrong once the API is being used regularly. Low priority.
- **Project/DB location management.** v0.1 auto-detects a project root and uses `<root>/modelrunnR.duckdb`, overridable via `options()`. But workflows involving multiple DBs per project, swapping between artifact stores, or archiving old runs are not addressed. Parked for later.
- **Ergonomics of rebinding and labels (validation pending).** Current direction is documented in *Variants and swappability* above: one polymorphic `rebind` argument that accepts bare R values or `mr_*()` reference constructors, plus an identity-conferring `label` argument with auto-propagation from labeled upstreams. Marked tentative because the unified shape needs implementation experience to validate — in particular, whether bare-value dispatch inside `rebind` feels natural or surprising in practice, and whether the auto-propagation warning on upstream disagreement is the right default.
- **Rerun semantics.** When the user asks to rerun one step, what happens to downstream steps? Just that step? Downstream-that's-stale? Upstream-that's-stale plus that step plus downstream? TBD.
- **Multi-script workflows.** How does the user run multiple scripts as a pipeline? Is there a `launch_all()` that discovers stale scripts and runs them in dependency order? TBD.
- **"Manage runs" API.** Shape of the introspection/control API — `run_status()`, `run_history()`, `forget_step()`, `drop_artifact()`, etc. TBD.
- **`rebind` + script `stow()` collisions (resolved — kept for discoverability).** If `launch(..., rebind = list(p = df))` is called and the script also calls `stow(..., "p")`, what semantics apply? **Resolution:** bindings and stows are separate axes — a rebind is a grab-side input override, a stow is an output-side write. Both happen independently: the rebound value governs `grab("p")` calls inside the script, and the stow records a new version for `p` as an output through the normal hybrid-versioning path. No collision.
- **Scope of "recent run records" for GC protection (partially resolved).** (Surfaced during planning of `docs/internal/plan.md` Slice 11.) `prune_versions()` protects versions referenced by "recent" run records unless `force = TRUE`. Versions whose producing run has a non-null `variant_label` are now **unconditionally protected** (see *User-facing API*), resolving the question for labeled-variant runs. For *unlabeled* runs, the original question remains open: what counts as "recent"? Candidates: all non-pruned runs, the last N runs, runs within an age window, or an explicit retention policy. Plan's tentative direction: all non-pruned runs. Revisit once version histories get large enough for the distinction to matter.
- **Code-as-data, future axis.** `_mr_runs.code_body` stores the code executed by every run (deparsed expression for inline, captured file bytes for scripts). This makes run rows self-contained — a run is recoverable even if its source file has been deleted. That property has implications beyond recovery: a DuckDB file with code + inputs + outputs is transportable enough to support **remote/async execution** (a worker on another machine pulls `code_body`, executes against the same DB, writes the result row back), **queue-then-run** semantics (write a row with `status = "queued"` and no results; a worker picks it up later), and **hand-off reproducibility** (ship the `.duckdb` file and the whole pipeline travels with it — no separate scripts directory). None of these are in v0.1 scope; noted here so the invariant isn't broken by accident.
- **Input-change rule for staleness (locked tentatively).** (Related to the open question already noted in *Staleness model* — surfaced again during planning of `docs/internal/plan.md` Slice 10.) A downstream input is considered "changed" only if the upstream content hash differs, not merely if the upstream run_id is newer. Plan commits to the stricter rule; design may relax it if real usage shows pain.

## Out of scope

modelrunnR will not include any of the following. If these needs arise, they belong in separate tools (or in a user's own code wrapping modelrunnR).

- **Production scheduling, retries, alerting.** Airflow / Prefect / Dagster territory. A user who needs production scheduling runs modelrunnR from their orchestrator; the orchestrator handles retries.
- **Arbitrary DAG orchestration.** targets territory. modelrunnR's step graph is whatever falls out from observing I/O across scripts; it is not a general-purpose workflow engine.
- **Experiment tracking in the MLflow sense.** modelrunnR records step runs for staleness and timing; it does not track metrics, parameters, or model registries as first-class concepts.
- **Model serving.** Not in scope under any circumstances.
- **Model specs as framework citizens.** modelrunnR has no opinions about what a model is. Model-spec abstractions live in user code or in a separate package.
- **Reporting and visualization.** Panelmodeler has `preset_*.R` files for this; they do not belong in modelrunnR.
- **Feature engineering primitives.** Panelmodeler has `feature_*.R` for this; they do not belong in modelrunnR.
- **Real-time / streaming data.** The tool assumes batch execution of finite R scripts.
- **Transactional SQL backends** (Postgres, MySQL, SQLite). modelrunnR's abstractions are designed for analytical workloads.
