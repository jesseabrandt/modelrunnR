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

Two primary functions, plus one entry point:

- **`read_table(name)`** — read a DuckDB table by name. If a table by that name does not exist but a flat file (CSV, parquet, etc.) with a conventional name/location does, the function may auto-ingest it into DuckDB as a first-run side effect. Exact auto-ingestion behavior is an open question. Outside a tracked run, behaves as a plain read.

- **`write_table(name, data)`** — write an R data frame to a DuckDB table. Outside a tracked run, behaves as a plain write. Inside a tracked run, also records the write in the current run's output list.

- **`run(script_path)`** — entry point for tracked execution. Sources `script_path` in an instrumented context that records `read_table()` / `write_table()` calls, measures wall-clock time, and writes a run record to the metadata table on completion. Equivalent to `source(script_path)` except that modelrunnR observes the side effects.

Function names are placeholders. `read_table` / `write_table` are likely not the final names — they don't clearly distinguish from `DBI::dbReadTable` or `dplyr::tbl`. Naming to be revisited before the first user-visible release.

### Execution flow

When `run(script_path)` is called:

1. Compute the content hash of the script file.
2. Open (or reuse) the DuckDB connection for the current artifact store.
3. Establish a recording context that instruments `read_table()` / `write_table()` calls made during the source.
4. `source()` the script in that context.
5. On completion (success or failure), write a run record to the metadata table with: step identifier (script path), code hash, observed inputs, observed outputs, start timestamp, duration, status.
6. Surface timing output to the user.

Errors during script execution should not prevent the run record from being written — a failed run is still a fact worth recording.

### Metadata (sketch)

A metadata table lives inside the same DuckDB file as the artifacts. Exact schema is provisional and will be nailed down during implementation. Rough shape:

| column | type | meaning |
|---|---|---|
| `step` | TEXT | script path, relative to project root |
| `run_id` | TEXT or BIGINT | unique identifier for this run |
| `code_hash` | TEXT | hash of script file contents at run time |
| `inputs` | TEXT (JSON) | list of tables observed to be read |
| `outputs` | TEXT (JSON) | list of tables observed to be written |
| `external_inputs` | TEXT (JSON) | user-declared external inputs (files, env vars) and their hashes |
| `started_at` | TIMESTAMP | run start time |
| `duration_ms` | BIGINT | wall-clock duration |
| `status` | TEXT | success / error / running |

The exact shape of `inputs` / `outputs` / `external_inputs` (JSON column vs. separate rows, how nested structure is stored) is TBD. Schema should use only portable SQL types so it can migrate to other analytical backends without a rewrite.

## Staleness model

A step is **stale** if any of the following hold:

1. Its script file's content hash differs from the most recent recorded run's `code_hash`.
2. Any of its observed inputs have been re-written by an upstream step since this step's most recent run.
3. Any of its declared external inputs (files, env vars) have changed since the most recent run.

A step is **fresh** only if none of the above hold.

The precise definition of "an input has changed" when the input is a DuckDB table (does the table itself have a hash? is it enough that the upstream step ran again?) is an open question. The likely answer is: track the `run_id` of the upstream step that produced each input, and consider an input changed if a newer upstream run exists.

"Stale" and "fresh" are advisory by default. The framework's job is to *tell* the user which steps are stale, not to silently skip reruns or silently auto-run. The user decides whether to act on staleness information. (This default may be revisited once real usage reveals whether silent skip-if-fresh is desired.)

## Open questions

Decisions deferred to later conversations or to implementation time. Each has a brief status note.

- **Function naming.** `read_table` / `write_table` are placeholders; final names TBD. Should distinguish from DBI and dplyr idioms.
- **CSV auto-ingestion by `read_table()`.** Does `read_table("raw")` look for `raw.csv` in a conventional location and auto-ingest on first access? Or does the user call a separate `ingest()` function? TBD.
- **Connection management.** Does modelrunnR auto-open a connection to a default DuckDB file (`./modelrunnR.duckdb`?) on first call? Or does the user call `connect()` explicitly? TBD.
- **Non-table outputs (model objects, etc.).** Serialize to a BLOB column in DuckDB? Write to the filesystem with a tracked path? Treat as ephemeral and re-fit when needed? Likely a mix depending on object size. TBD.
- **Helper file hashing.** If a tracked script `source()`s a helper file, should the helper's contents contribute to the code hash? Leaning yes (hash all `source()`d files inside a step), but TBD.
- **Interactive vs scripted runs.** Should `read_table()` / `write_table()` calls from the REPL be tracked? Leaning no — only `run(script)` boundaries are tracked; interactive use is untracked but functional.
- **Branchy scripts.** If a script reads different tables on different runs depending on branching logic, how does staleness handle it? Leaning: record what actually happened this run; accept fuzziness.
- **Parameter sweeps.** One script, multiple runs with different hyperparameters — how are they distinguished? Leaning: in v0.1, use separate script files. A parameter-aware variant can come later if needed.
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
