# modelrunnR Design

**Status**: Initial design, pre-implementation. Subject to revision as implementation surfaces new questions.

**Last updated**: 2026-04-08

---

## What modelrunnR is

modelrunnR is a minimal step-runner for iterative model experimentation in R. It provides two primary functions — placeholder names `read_table()` and `write_table()` — that replace the CSV reads and writes in an existing R analysis script. When a script is executed through modelrunnR's entry point, the framework observes which tables the script reads and writes, hashes the script contents, and uses that information to track staleness, timing, and run history. All intermediate results live in DuckDB. The user works with normal R scripts, not a pipeline DSL or declarative configuration format.

modelrunnR is inspired by the orchestration layer of [panelmodeler](../../../Practicum_AI_Branch/panelmodeler) — specifically `runner.R`, `harness_*.R`, `model.R`, `model_specs.R`, `new_model_spec.R`, `python_model.R`, and `stack.R` — but deliberately extracts only the step-running concern. It does not include panelmodeler's ingest, feature engineering, reporting, or exploration layers.

## Core design principles

These are the load-bearing commitments. Each is non-negotiable without explicit revision.

### The script is the step; the I/O calls are the declarations

modelrunnR has no `step()` wrapper, no registration function, no pipeline definition file, no DSL. A "step" in modelrunnR is identified by a script file path. Its code is the contents of that file. Its inputs and outputs are observed at runtime by watching calls to `read_table()` and `write_table()` inside the script. There is no separate declaration layer to maintain alongside the code — the I/O calls are themselves the declarations.

This is the single most important property of the design. Everything else falls out from it.

### Progressive disclosure

The MVP user interacts with modelrunnR through exactly two functions: `read_table()` and `write_table()`. They do not need to learn anything else to get staleness tracking, timing, and run history. Additional API surface (inspection, forced reruns, cleanup, run metadata queries) is layered on top and only needed when the user wants to *manage* their runs, not just execute them.

A corollary: the adoption path from "existing R script that reads a CSV and fits a model" to "modelrunnR-tracked step" is a two-line change plus an entry-point swap (`source(script)` → `modelrunnR::run(script)`).

### DuckDB-native in v0.1; analytical-SQL-capable in the seams

All intermediate results live in DuckDB. This is not an accident of convenience — it is a deliberate decision driven by the observation that panel data work is far better served by a columnar analytical database than by serialized R objects or flat files.

At the same time, modelrunnR's internal code should route all database interaction through a narrow interface (roughly: `read_table`, `write_table`, `table_exists`, `drop_table`, `list_tables`, `execute_sql`, and the metadata helpers). Core logic should avoid DuckDB-dialect-specific SQL (`READ_PARQUET`, `SUMMARIZE`, `PIVOT`, `LIST`/`STRUCT` types) and should lean on DBI where portable SQL suffices. DuckDB-specific features that are needed for v0.1 performance should be isolated in a single backend file (e.g., `R/backend_duckdb.R`).

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

Rejected because it adds a modal gate at exactly the wrong moment in the user's adoption flow. "Your first run created a candidate step — please approve it before continuing" is the kind of ceremony that causes users to abandon the tool. Cleaner alternative: auto-create step records on run, provide a delete-later API (e.g., `forget_step()`) for cleanup. The user is already expressing intent to track by choosing `run()` over plain `source()` — there is no second approval decision to make.

### Explicit `step()` wrapper

Rejected in favor of "the script is the step." Explicit wrappers add ceremony without adding information — the framework can observe everything a wrapper would declare, and the script file is already a natural boundary for R code. This is closely related to the progressive-disclosure principle: the MVP user shouldn't need to learn a wrapper syntax.

## MVP architecture

This section is specific enough to guide implementation but intentionally leaves details open where the design hasn't converged.

### User-facing API (v0.1)

All function names below are placeholders; final naming to be revisited before the first user-visible release.

**Primary functions**:

- **`read_table(name, source = NULL, version = NULL, from_run = NULL, as_of = NULL)`** — read a table. With no modifiers, returns the current latest version. If `source` is given and the table does not exist, `ingest()` is called under the hood. If `source` is given and the table exists with a different source hash, `ingest()` is called again and produces a new version (the old version remains queryable — see Versioning below). `version`, `from_run`, and `as_of` select specific historical versions. Outside a tracked run, behaves as a plain read.

- **`write_table(name, data)`** — write an R data frame to a DuckDB table. Inside a tracked run, the write is recorded as an output. Outside a tracked run (e.g., from the REPL), the write is recorded under a synthetic interactive step identifier; see Interactive I/O below.

- **`ingest(name, source)`** — read a flat file (CSV, parquet, etc.) and load it into DuckDB as the named table, recording the source file path and content hash in metadata. Callable explicitly or implicitly via `read_table(name, source = ...)`.

- **`save_artifact(name, object)`** / **`load_artifact(name)`** — persist and retrieve non-table outputs; see Non-table outputs below.

- **`run(script_path)`** — entry point for tracked execution. Sources `script_path` in an instrumented context, records observed I/O, measures wall-clock time, and writes a run record to the metadata table on completion.

- **`db_path()`** — inspector; returns the currently-active DuckDB file path.

- **`versions(name)`** — list all versions of a logical table or artifact. Returns a data frame with hash, first/last seen timestamps, size, and producing runs.

- **`prune_versions(name = NULL, keep = NULL, keep_latest = FALSE, older_than = NULL, ...)`** — explicit, user-invoked garbage collection. Policy arguments include `keep = N` (most recent N), `keep_latest = TRUE` (only the current), `older_than = "30d"` (time-based). Versions referenced by recent run records are protected from pruning unless the user passes `force = TRUE`. Called without a name, applies to all tables and artifacts.

**Configuration** is managed via R `options()`, not setter functions:

- `options(modelrunnR.db = "path/to/custom.duckdb")` overrides the default DuckDB location.
- `options(modelrunnR.blob_threshold = n_bytes)` sets the artifact BLOB-vs-filesystem threshold (default 10 MB).

There is no `connect()` function — the name would collide with `DBI::dbConnect()` idioms, and options-based configuration keeps the API surface smaller.

### Execution flow

When `run(script_path)` is called:

1. Compute the content hash of the script file.
2. Open (or reuse) the DuckDB connection for the current artifact store.
3. Establish a recording context that instruments `read_table()` / `write_table()` calls made during the source.
4. `source()` the script in that context.
5. On completion (success or failure), write a run record to the metadata table with: step identifier (script path), code hash, observed inputs, observed outputs, start timestamp, duration, status.
6. Surface timing output to the user.

Errors during script execution should not prevent the run record from being written — a failed run is still a fact worth recording.

### Versioning and non-destructive writes

Writes to tables and artifacts in modelrunnR are non-destructive by default. Every write is content-addressed, deduplicated, and preserved. The user opts into cleanup via explicit garbage collection (`prune_versions()`).

The approach is a **hybrid**: content-addressed physical storage combined with a temporal metadata layer. Physical storage is like a git object store — keyed by the hash of what's inside. The metadata layer adds timestamps, run identifiers, and logical names on top, so users get temporal semantics without losing dedup.

#### Physical layer

When `write_table("features", df)` is called:

1. Compute a stable, order-independent content hash of `df` (exact algorithm TBD; likely a streaming aggregate hash over sorted rows using DuckDB's built-in `hash()` function).
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
| `step` | TEXT | script path, relative to project root |
| `run_id` | TEXT or BIGINT | unique identifier for this run |
| `code_hash` | TEXT | hash of script + helper files at run time |
| `inputs` | TEXT (JSON) | list of `{name, hash}` pairs for tables read |
| `outputs` | TEXT (JSON) | list of `{name, hash}` pairs for tables and artifacts written |
| `external_inputs` | TEXT (JSON) | declared external inputs (files, env vars) and their hashes |
| `started_at` | TIMESTAMP | run start time |
| `duration_ms` | BIGINT | wall-clock duration |
| `status` | TEXT | `success` / `error` / `running` |

Temporal semantics come from joining these: "what did run 42 produce for `features`?" → look up `_mr_runs` for run 42, find the `features` hash in its `outputs`, then resolve via `_mr_versions` to the physical table.

Schema uses only portable SQL types so the metadata layer can migrate to other analytical backends without a rewrite.

#### Read API

```r
# Read current latest (the normal case)
read_table("features")

# Read a specific version
read_table("features", version = "ab3f7...")        # by content hash
read_table("features", from_run = "run_42")         # via run metadata
read_table("features", as_of = "2026-04-08 14:00")  # as-of-time lookup

# Inspect history
versions("features")
# -> data.frame with columns: content_hash, first_seen, last_seen,
#    size_bytes, produced_by_runs
```

#### Garbage collection

Versioning is non-destructive by design, so disk grows over time. Two mechanisms for cleanup:

**Automatic warning** when a logical table accumulates more than `getOption("modelrunnR.version_warn_threshold", 20)` versions. The warning surfaces on the next write or the next `run()` call, telling the user to consider running `prune_versions()`. No automatic pruning ever happens.

**Explicit pruning** via `prune_versions()` (see User-facing API above). Policy arguments control what gets kept: `keep = N`, `keep_latest = TRUE`, `older_than = "30d"`. Versions referenced by recent run records (even if not "latest") are protected from pruning unless the user passes `force = TRUE` — this prevents gc from silently breaking `read_table(..., from_run = ...)` queries.

#### Cost model

Content hashing adds per-write overhead. For small tables this is negligible; for very large tables (tens of millions of rows) hashing costs non-trivial time and should use a fast streaming aggregate rather than materializing the full serialization in memory. Exact hash algorithm is TBD pending a survey of DuckDB's aggregate-hash capabilities, but the target is: stable across row/column order (so "the same data" always produces the same hash), fast (can handle ~100M rows in seconds), and deterministic (no salt).

### Connection and project layout

modelrunnR auto-opens a DuckDB connection on first call to any table-facing function. The user never invokes an explicit connection function.

The default DuckDB file path is determined by walking up the filesystem from the current working directory looking for project markers, in order: `DESCRIPTION`, `.Rproj`, `.git/`, `renv.lock`, `.here`. If a project root is found, the default path is `<project_root>/modelrunnR.duckdb`. If no root is found, the default is `<cwd>/modelrunnR.duckdb` and modelrunnR emits a warning suggesting the user add a project marker so the DB location becomes stable across subdirectories.

The user overrides the default via `options(modelrunnR.db = "path")` at any time before the first table-facing call — typically at the top of a script or in `.Rprofile`.

Connection lifecycle: lazy-opened on first use, reused for the rest of the R session, closed via a finalizer on session exit. `db_path()` surfaces the current path for inspection.

The project-root walker should be implemented internally (~20 lines) rather than depending on `here` or `rprojroot`, to keep Imports lean.

### Non-table outputs (artifacts)

Step outputs that are not naturally tables — fitted model objects, serialized objects from other languages, images, etc. — are persisted via `save_artifact()` / `load_artifact()`.

- **Serialization**: `qs::qsave()` (fast, compact; adds `qs` to Imports). Chosen over base `serialize()` / `saveRDS()` because it handles R model objects substantially better.
- **Storage dispatch**: objects whose serialized size is below `getOption("modelrunnR.blob_threshold")` (default 10 MB) are stored as a BLOB row in the metadata table inside the DuckDB file. Objects above the threshold are written to `./modelrunnR_artifacts/<name>.qs` on the filesystem, with the path recorded in metadata. Small artifacts preserve the "one DuckDB file = entire artifact store" property; large artifacts escape to the filesystem rather than bloating the DB file.
- **Namespace**: artifacts and tables share a single unified namespace. A name cannot refer to both. `save_artifact("features", ...)` errors if `features` already exists as a table, and vice versa. Checked at write time.
- **Tracking**: artifacts appear in a step's `outputs` alongside tables and participate in staleness detection identically.

### Interactive I/O

`read_table()` and `write_table()` can be called outside a `run()` boundary — from the REPL, from a plain `source()`, or from any untracked R code. Behavior:

- **Interactive writes** are recorded with a synthetic step identifier of the form `<interactive:YYYY-MM-DD HH:MM:SS>`. This captures the fact that a table was mutated outside any reproducible script.
- **Interactive reads** are *not* recorded. Reads don't change state, and recording every REPL exploration would clutter the metadata without benefit.
- **Reproducibility warnings**: when a scripted run's recorded inputs include a table whose most recent write came from an interactive session, modelrunnR warns the user at run time: *"step `X` reads `Y`, which was last written interactively on [timestamp]. This step is not fully reproducible from source."*

This catches the "I manually patched a table in the REPL and then a script started depending on it" failure mode, which is exactly the kind of non-reproducibility land mine the framework should surface.

## Staleness model

A step is **stale** if any of the following hold:

1. Its script file's content hash differs from the most recent recorded run's `code_hash`.
2. Any of its observed inputs have been re-written by an upstream step since this step's most recent run.
3. Any of its declared external inputs (files, env vars) have changed since the most recent run.

A step is **fresh** only if none of the above hold.

The precise definition of "an input has changed" when the input is a DuckDB table (does the table itself have a hash? is it enough that the upstream step ran again?) is an open question. The likely answer is: track the `run_id` of the upstream step that produced each input, and consider an input changed if a newer upstream run exists.

**Helper files.** When a tracked script `source()`s a helper file, the helper's content contributes to the step's code hash. The instrumentation wraps `source()` during a tracked run to record each loaded file's path and content hash, recursively (with cycle detection). The effective code hash is `hash(script_contents + sorted_helper_hashes)`. Installed packages, base R, and `.Rprofile` are explicitly *not* hashed — use renv/pak for package reproducibility; declare environment variables or external files as external inputs if they matter for your step.

**Branchy scripts.** If a script reads different tables on different runs due to branching logic, the instrumentation records only what actually executed. Staleness for the next run is evaluated against the most recent run's recorded inputs. If a different branch executes on a rerun, the new run gets a new record and staleness proceeds against the new inputs. No branch prediction, no coverage analysis — the metadata is a faithful log of what actually happened.

"Stale" and "fresh" are advisory by default. The framework's job is to *tell* the user which steps are stale, not to silently skip reruns or silently auto-run. The user decides whether to act on staleness information. (This default may be revisited once real usage reveals whether silent skip-if-fresh is desired.)

## Open questions

Decisions deferred to later conversations or to implementation time. Each has a brief status note.

- **Function naming.** `read_table`, `write_table`, `ingest`, `save_artifact`, etc. are all placeholders. Final names should distinguish from DBI and dplyr idioms. TBD.
- **Project/DB location management.** v0.1 auto-detects a project root and uses `<root>/modelrunnR.duckdb`, overridable via `options()`. But workflows involving multiple DBs per project, swapping between artifact stores, or archiving old runs are not addressed. Parked for later.
- **Parameter sweeps.** One script, multiple runs with different hyperparameters — how are they distinguished? (User has design thoughts; to be discussed next.)
- **Rerun semantics.** When the user asks to rerun one step, what happens to downstream steps? Just that step? Downstream-that's-stale? Upstream-that's-stale plus that step plus downstream? TBD.
- **Multi-script workflows.** How does the user run multiple scripts as a pipeline? Is there a `run_all()` that discovers stale scripts and runs them in dependency order? TBD.
- **"Manage runs" API.** Shape of the introspection/control API — `run_status()`, `run_history()`, `forget_step()`, `drop_artifact()`, etc. TBD.

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
