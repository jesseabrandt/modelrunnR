# modelrunnR v0.1 Implementation Plan

**Status**: Draft. Sequences the work in `docs/design.md` into vertical slices.
Companion to the design doc — defers all semantics to it and only decides *what
order* to build things in.

**Last updated**: 2026-04-08

---

## How to use this plan

- Each slice is **vertical**: it ships something a user could exercise
  end-to-end before moving on. No slice leaves the package in a state where a
  previously-working example stops working.
- Slices are sized for a commit-per-slice cadence at minimum; more granular
  commits within a slice are encouraged (TDD, frequent commits).
- **Design-doc-first.** If a slice's behavior is unclear, the design doc is
  the tiebreaker. This plan does not re-derive semantics — it only sequences.
- **Open questions that surfaced while planning** are listed at the bottom and
  appended to `docs/design.md` under *Open questions*.

## Conventions the plan assumes

These are not new decisions; they just make the slices below unambiguous.

- Internal backend primitives are **private** (`.mr_` prefix, not exported),
  distinct from user-facing `grab`/`stow` names, per the design's "narrow
  DBI-based interface" commitment.
- DuckDB-specific SQL lives in `R/backend_duckdb.R`. Other files use portable
  DBI calls.
- JSON columns (`inputs`, `outputs`, `external_inputs`) are encoded via
  `jsonlite`. Added to Imports when first needed (Slice 3).
- Package-level state (active recording context, pin map, launch flag) lives
  in an internal environment `.mr_state` (created in `R/zzz.R` via
  `new.env(parent = emptyenv())`), not in `.GlobalEnv` or `options()`.
- Every slice ends with `devtools::document()`, `devtools::test()`, and
  `devtools::check()` clean before commit.

## Slice dependency graph

```
 1. core loop ──┬──> 2. project root
                │
                └──> 3. versioning ──┬──> 4. ingest
                                     ├──> 5. artifacts ───> 6. interactive I/O
                                     │                           │
                                     │                           v
                                     └──> 7. helper hashing ──> 8. external inputs
                                                                    │
                                                                    v
                                                               9. pin + data
                                                                    │
                                                                    v
                                                              10. staleness
                                                                    │
                                                                    v
                                                           11. prune + warnings
```

Slice 2 can run in parallel with Slice 3 if desired. Everything else is a
chain.

---

## Slice 1 — Core loop: `launch` + naive `grab`/`stow` + `_mr_runs`

**Goal.** Smallest thing that exercises the core loop. A user can
`launch("script.R")` where the script calls `stow("out", df)` and a later
launch reads it via `grab("out")`. Overwriting semantics. Tables only. One
row per run in a simplified `_mr_runs`. No versioning, no hashing, no
artifacts, no helper tracking.

**Files built.**

- `R/backend_duckdb.R` — narrow DBI primitives: `.mr_connect()`,
  `.mr_disconnect()`, `.mr_table_read()`, `.mr_table_write()` (overwrite),
  `.mr_table_exists()`, `.mr_execute()`, `.mr_list_tables()`.
- `R/zzz.R` — creates `.mr_state` internal environment; registers a session
  finalizer that closes the connection.
- `R/connection.R` — lazy connection cache keyed by db path; uses
  `.mr_connect()`.
- `R/db_path.R` — default path = `file.path(getwd(), "modelrunnR.duckdb")`
  (project-root walker lands in Slice 2). `options(modelrunnR.db = ...)`
  override. `db_path()` exported inspector.
- `R/schema.R` — `_mr_runs` DDL with portable types (`step`, `run_id`,
  `inputs` TEXT/JSON, `outputs` TEXT/JSON, `started_at` TIMESTAMP,
  `duration_ms` BIGINT, `status` TEXT). Run migrations on first connect.
  (`code_hash` and `external_inputs` arrive later.)
- `R/recording.R` — per-launch recording context stored in `.mr_state`.
  Functions: `.mr_start_recording()`, `.mr_stop_recording()`,
  `.mr_record_read()`, `.mr_record_write()`, `.mr_is_recording()`.
- `R/grab.R` — reads a table by logical name via `.mr_table_read()`. When
  recording, calls `.mr_record_read(name)`. When not, plain read.
- `R/stow.R` — `is.data.frame` check; data frames write via
  `.mr_table_write()`. When recording, calls `.mr_record_write(name)`. Errors
  cleanly on non-data-frame values (artifacts land in Slice 5).
- `R/launch.R` — opens/reuses connection, starts recording, `source()`s the
  script in a fresh environment, captures errors with `tryCatch`, measures
  `Sys.time()` start/duration, writes a `_mr_runs` row (with observed
  `inputs`/`outputs`, status `success`/`error`), stops recording, prints a
  one-line wall-clock summary, returns the run row invisibly.
- `R/modelrunnR-package.R` — already exists; add `@importFrom` stubs as
  needed.

**Dependencies added to `Imports`.** `DBI`, `duckdb`, `jsonlite`.

**Tests** (`tests/testthat/`):

- `test-db_path.R` — default resolves to cwd; `options(modelrunnR.db = …)`
  overrides; `db_path()` returns the current path.
- `test-connection.R` — lazy open; repeated calls reuse the cached connection;
  teardown closes cleanly.
- `test-core-loop.R` — `launch("stow_script.R")` then
  `launch("grab_script.R")` round-trips a frame identical in columns and row
  count.
- `test-run-record.R` — `inputs` and `outputs` on the run row match exactly
  what the script grabbed/stowed; success status recorded.
- `test-failed-run.R` — a deliberate `stop()` in the script still produces a
  `_mr_runs` row with `status = "error"` and a sensible non-NA `duration_ms`.
- `test-stow-bad-type.R` — `stow("x", list())` errors with a message pointing
  at the non-data-frame cause.
- `test-plain-io.R` — `grab`/`stow` called outside `launch()` work as plain
  read/write with no recording side effects.

**Deferred** (will be picked up by later slices, explicitly not in Slice 1):
project-root walker; content hashing; `_mr_versions`; artifacts; interactive
tracking (stow-outside-launch currently produces no synthetic step row);
`code_hash`; `external_inputs`; `pin`/`data`; staleness; `ingest()`; timing
decomposition (DB vs user code).

**Ship check.** Two scripts, one writes, one reads, `_mr_runs` has two rows,
`db_path()` tells the user where the file lives.

---

## Slice 2 — Project-root walker

**Goal.** Stable db path across subdirectories of a project.

**Files built.**

- `R/project_root.R` — walks up from `getwd()` checking, in order,
  `DESCRIPTION`, `.Rproj`, `.git/`, `renv.lock`, `.here`. Returns the first
  hit or `NULL`. Target: ≤20 LOC, no new deps (design: "implemented internally
  rather than depending on `here`/`rprojroot`").
- `R/db_path.R` — updated to consult the walker. If it returns a root, default
  path becomes `file.path(root, "modelrunnR.duckdb")`. If not, default path is
  `file.path(getwd(), "modelrunnR.duckdb")` *and* a warning suggests adding a
  project marker.

**Tests** (`test-project_root.R`): fixtures with each marker at various
depths; walker finds them; precedence respected when multiple markers exist;
no marker → warning + cwd fallback; `db_path()` is stable across
`setwd()`-ing into subdirectories of a fake project.

**Deferred.** Multi-db-per-project workflows, archival of old DB files — both
called out in the design doc as open questions for later.

**Ship check.** `cd` into a subdirectory of the `modelrunnR` package itself
and call `db_path()` — it returns the package-root DB path, not the
subdirectory's.

---

## Slice 3 — Content-hashed versioning for tables

**Goal.** `stow()` becomes non-destructive. Every distinct content gets its
own physical table. Logical name resolves to the latest via a view. Historical
versions are addressable by content hash, run id, or as-of time.

**Files built.**

- `R/backend_duckdb.R` — add `.mr_hash_frame(df)`: writes the frame to a
  transient temp table, runs an order-independent aggregate hash using
  DuckDB's `HASH()` function over all columns, returns a hex string. This is
  DuckDB-specific and lives here by design.
- `R/schema.R` — add `_mr_versions` DDL with columns from design §Versioning:
  `logical_name`, `content_hash`, `physical_name`, `kind`, `first_seen`,
  `last_seen`, `size_bytes`. Migration path for existing DBs created under
  Slice 1 so they can gain the new table on next connect.
- `R/stow.R` — new flow for data frames:
  1. `hash <- .mr_hash_frame(value)`
  2. `physical_name <- .mr_physical_name(name, hash)` (e.g.,
     `"<name>__<first16(hash)>"`, chosen to stay within DuckDB identifier
     limits while remaining readable in `SHOW TABLES`)
  3. If the physical table doesn't exist, create it and insert a
     `_mr_versions` row with `first_seen` = `last_seen` = now.
  4. If it exists, update `last_seen` to now. No physical write.
  5. `CREATE OR REPLACE VIEW <name> AS SELECT * FROM <physical_name>`
  6. `.mr_record_write(name, hash)` — the recorder now tracks `{name, hash}`
     pairs, not just names.
- `R/grab.R` — default path resolves via the view. New selectors:
  - `version = <hash>` → `_mr_versions` lookup → read that physical table.
  - `from_run = <run_id>` → `_mr_runs.outputs` lookup → find this name's hash
    in that run → resolve via `_mr_versions`.
  - `as_of = <timestamp>` → `_mr_versions` rows for this name with
    `first_seen <= as_of`, picking the one with the greatest `first_seen`.
- `R/launch.R` — `_mr_runs.inputs`/`outputs` columns now carry JSON arrays of
  `{name, hash}` pairs. Recording now captures hashes alongside names.
- `R/versions.R` — exported `versions(name)`; joins `_mr_versions` with
  `_mr_runs` to produce one row per version with `content_hash`, `first_seen`,
  `last_seen`, `size_bytes`, and `produced_by_runs` (a list-column of run ids).

**Tests** (`test-versioning.R`, `test-versions-fn.R`):

- Stowing the same frame twice yields one physical table, one `_mr_versions`
  row; `last_seen` advances on the second write.
- Stowing a modified frame yields a second physical table and a second
  `_mr_versions` row; the view resolves to the newer hash.
- `grab("x", version = h)` returns exactly the frame that hashed to `h`, not
  latest.
- `grab("x", from_run = rid)` returns the frame that run produced, even when
  newer versions exist.
- `grab("x", as_of = ts)` returns the version that was latest at `ts`.
- Row/column reordering produces the *same* hash (order-independence is the
  contract the design commits to).
- `versions("x")` returns the documented columns; rows align with actual
  history.

**Deferred.** Version-count warnings and `prune_versions()` (Slice 11).
Artifact hashing (Slice 5 reuses the `.mr_hash_*` pattern over bytes).

**Algorithm shipped.** Per-row `HASH(c1, c2, …)` over columns in sorted
column-name order, then `MD5(STRING_AGG(CAST(row_hash AS VARCHAR), '|' ORDER BY
row_hash))` as the whole-frame hash. Row-order invariance comes from the
`ORDER BY` inside `STRING_AGG`; column-order invariance comes from sorting
column names before hashing. Multiplicity is preserved because `STRING_AGG`
emits one token per row.

**Rejected alternatives.** `SUM(HASH(c1) # HASH(c2) # …)` with `#` = XOR was
the initial sketch but was discarded during Slice 3:

- XOR is **multiplicity-insensitive**: two copies of the same row cancel
  (`h XOR h = 0`), so `{r, r}` would hash the same as `{}` for any row whose
  columns produce the same partial XOR. The "preserves multiplicity" contract
  would fail silently.
- Plain `SUM` over DuckDB `HASH()` (which returns `UBIGINT`) wraps modulo 2^64
  — still deterministic, but combined with XOR it compounds the loss.

The STRING_AGG approach is O(N) intermediate memory (not streaming), which is
acceptable at v0.1 scale; a true streaming alternative is noted in
`docs/followups.md` for when run histories exceed ~100M rows per frame.

One caveat: `ORDER BY HASH(cols)` is a 64-bit total order, so collisions
(~0.03% probability at 100M distinct rows per frame) could defeat row-order
invariance on the colliding tie. Acceptable at v0.1 scale; a tiebreaker is
listed in followups.

**Ship check.** Run the same script three times with a changing RNG seed →
three physical tables, three `_mr_versions` rows, and
`grab("out", from_run = rid_first)` returns the first run's exact output.

---

## Slice 4 — `ingest()`

**Goal.** Users can load flat files into DuckDB through modelrunnR and get the
source recorded. Design's "if `source` is given and `name` does not exist,
`ingest()` is called under the hood" path becomes real.

**Files built.**

- `R/backend_duckdb.R` — add `.mr_read_file(path)`: dispatches on extension to
  DuckDB `read_csv_auto()` / `read_parquet()`. DuckDB-specific; lives here.
- `R/hash_file.R` — `.mr_file_hash(path)`: stable hash over file bytes, using
  DuckDB `HASH()` on a BLOB read from disk so we don't add `digest` as a
  dependency.
- `R/schema.R` — add `source_uri` TEXT and `source_hash` TEXT columns to
  `_mr_versions` (both nullable; script outputs leave them NULL). Migration
  for existing DBs.
- `R/ingest.R` — exported `ingest(name, source)`: reads the file into a data
  frame via `.mr_read_file()`, then writes via the normal `stow()` pathway so
  content-hashing, physical-table creation, and view resolution all reuse
  Slice 3. After stow, updates the just-inserted `_mr_versions` row with
  `source_uri` and `source_hash`.
- `R/grab.R` — new `source = <path>` argument:
  - If `name` doesn't exist, call `ingest()` and proceed.
  - If `name` exists and the current file's hash differs from the latest
    `_mr_versions.source_hash` for this name, call `ingest()` again (producing
    a new version naturally via Slice 3's flow).
  - If the file's hash matches, skip re-ingest and return the cached table.

**Tests** (`test-ingest.R`):

- `ingest("iris", "iris.csv")` creates a table; `versions("iris")` shows
  `source_uri` and `source_hash` populated.
- `grab("iris", source = "iris.csv")` on a cold DB triggers ingest.
- A second call reuses the cache (no new version).
- Modifying the CSV bytes → next `grab(..., source = …)` ingests a new
  version.
- A parquet source works through the same path.

**Deferred.** URL sources, partitioned datasets, schema validation — none
are v0.1 targets.

**Ship check.** The demo flow `raw <- grab("raw", source = "data.csv")` then
`stow("features", transform(raw))` runs once to ingest + build, a second
time with the same CSV to reuse both versions.

---

## Slice 5 — Artifacts (non-table `stow`)

**Goal.** `stow("model", fit)` stores non-data-frame R objects under the same
logical namespace as tables. `grab("model")` returns the original object.

**Files built.**

- `qs` added to `Imports` (design commits to `qs`).
- `R/backend_duckdb.R` — add `.mr_hash_bytes(raw)`: hashes a raw vector via
  DuckDB `HASH()` on a BLOB (consistent with `.mr_file_hash()`).
- `R/schema.R` — add `_mr_artifacts` table: `physical_name` PK, `payload`
  BLOB. Used for small artifacts. `_mr_versions.kind` (already present) is
  set to `artifact` for these rows.
- `R/stow.R` — dispatch updated:
  - `is.data.frame(value)` → Slice 3 table path (unchanged).
  - else → artifact path:
    1. `bytes <- qs::qserialize(value)`
    2. `hash  <- .mr_hash_bytes(bytes)`
    3. If `length(bytes) < getOption("modelrunnR.blob_threshold", 10*1024*1024)`,
       insert `(physical_name, payload)` into `_mr_artifacts`.
    4. Else write `./modelrunnR_artifacts/<name>__<short_hash>.qs` to disk
       (create the directory lazily).
    5. Insert a `_mr_versions` row with `kind = "artifact"` and
       `physical_name` pointing to the storage location (BLOB row id or file
       path).
  - **Namespace guard.** Before inserting, look up any existing
    `_mr_versions` rows for `name`; if any exist with a different `kind`,
    error with a clear message ("`name` already exists as a table/artifact;
    use a different name").
- `R/grab.R` — resolves `kind` from `_mr_versions`. For artifacts, load BLOB
  or read file, `qs::qdeserialize()`, return the object. All selectors
  (`version`, `from_run`, `as_of`) work identically to tables.

**Tests** (`test-artifacts.R`):

- `stow("fit", lm(mpg ~ wt, mtcars))` round-trips: `grab("fit")` returns an
  `lm` whose `coef()` matches.
- Small artifacts land in `_mr_artifacts`; artifacts over the threshold land
  on disk.
- `options(modelrunnR.blob_threshold = n)` is honored.
- `stow("x", df)` then `stow("x", model)` errors on the second call
  (namespace collision).
- An artifact appears in `_mr_runs.outputs` and is reachable via
  `grab("fit", from_run = rid)`.

**Deferred.** Python-language artifacts; compression tuning beyond qs
defaults; alternative serialization formats.

**Ship check.** A fitted model survives `stow`/`grab`, its prior version is
recoverable via `from_run`, and its prior file on disk (if above threshold)
still exists.

---

## Slice 6 — Interactive I/O tracking

**Goal.** `stow()` calls outside a `launch()` get recorded as synthetic
interactive steps. Later launches warn when they grab names whose most recent
producer was an interactive session.

**Files built.**

- `R/recording.R` — when `stow()` is called and `.mr_is_recording()` is
  false, build a synthetic step id of the form
  `sprintf("<interactive:%s>", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))` and
  insert a lightweight `_mr_runs` row with that `step`, a fresh `run_id`, an
  empty `inputs`, an `outputs` entry for this write, `duration_ms = 0`, and
  `status = "interactive"`. Reads (`grab()` outside launch) continue to write
  nothing — design explicitly does not record interactive reads.
- `R/launch.R` — after the script finishes sourcing and inputs have been
  observed, for each observed input look up the most recent `_mr_runs` row
  that *produced* that name. If the producing row's `step` starts with
  `<interactive:`, call `warning()` with the exact wording the design
  specifies: *"step `X` grabs `Y`, which was last stowed interactively on
  [timestamp]. This step is not fully reproducible from source."*

**Tests** (`test-interactive.R`):

- `stow("x", df)` at the REPL creates a `_mr_runs` row whose `step` starts
  with `<interactive:`.
- `grab("x")` at the REPL produces no new `_mr_runs` row.
- Launching a script that `grab("x")`s after an interactive stow emits the
  reproducibility warning with the expected wording.
- Launching a script whose inputs are all script-produced does not warn.

**Deferred.** Richer provenance (session id, user, host).

**Ship check.** The "I patched a table from the REPL" failure mode is visibly
surfaced on the next launch.

---

## Slice 7 — Helper file hashing + `code_hash`

**Goal.** A launched step's code hash covers the script *and* every file it
`source()`s, recursively. This is the content-hash arm of staleness.

**Files built.**

- `R/schema.R` — add `code_hash` TEXT to `_mr_runs`. Migration adds it
  nullable on existing DBs.
- `R/helper_tracking.R` — within a launch, replace `base::source` in the
  script's evaluation environment with a wrapper that:
  1. Resolves the file path via `normalizePath()`.
  2. Computes its byte hash.
  3. Adds `(path, hash)` to a per-launch `helpers` set in the recording
     state. Skip if already present (cycle/duplicate guard).
  4. Calls the original `source()`.
  Restore the original binding on launch exit.
- `R/hash_code.R` — `.mr_code_hash(script_bytes, helpers_set)`:
  `hash(script_bytes || newline || sorted_helper_hashes_joined)`. Order-stable
  across runs. Implementation uses the same DuckDB-`HASH()`-over-BLOB pattern
  as Slice 4/5 for consistency.
- `R/launch.R` — after `source()` returns (or errors), compute `code_hash`
  from the observed script and the accumulated helpers set, store it on the
  run row.

**Tests** (`test-helper-hashing.R`):

- A script with no helpers: `code_hash` == hash of the script file alone.
- A script that sources helper A: `code_hash` changes when A's bytes change.
- A script sourcing A which sources B: `code_hash` is influenced by B.
- Cyclic sourcing (A→B→A) terminates; each unique file hashed once.
- Installed-package changes do not affect `code_hash` (explicit
  non-requirement from the design).

**Deferred.** Hashing files loaded via `devtools::load_all()`,
`sys.source()`, or `box::use()` — not v0.1 targets.

**Ship check.** Edit a helper → next launch's run row has a new `code_hash`.

---

## Slice 8 — External inputs declaration

**Goal.** Users can declare files and env vars that should contribute to
staleness via `launch(..., external_inputs = …)`. No staleness check yet —
Slice 11 consumes these.

**Files built.**

- `R/schema.R` — add `external_inputs` TEXT (JSON) column to `_mr_runs`.
- `R/launch.R` — accepts `external_inputs = list(files = c(…), env = c(…))`.
  Before running the script:
  - For each file path, compute `.mr_file_hash(path)`; record `{path, hash}`.
    Missing files error before `source()` is called.
  - For each env var name, read via `Sys.getenv()`; record
    `{name, hash_of_value}`.
  - Serialize to JSON and stash on the run row when written.

**Tests** (`test-external-inputs.R`):

- A declared env var records its value hash; changing it between runs yields
  different recorded hashes.
- A missing declared file errors before the script runs, so no `_mr_runs`
  row is written for that launch.
- `external_inputs` round-trips cleanly through the JSON column.

**Deferred.** Globs, URLs, remote files.

**Ship check.** A step listing `data_version.txt` as an external input shows
a different `external_inputs` hash after the file changes on disk.

---

## Slice 9 — `pin` and `data` (parameter sweeps)

**Goal.** Make the xgboost sweep example in design.md §*Parameter passing
and sweeps* work.

**Files built.**

- `R/launch.R` — accept two new args:
  - `pin = list(name = hash_or_run_id)` — during recording, `grab(name)`
    inside the script resolves to the pinned hash instead of latest. The pin
    map lives in `.mr_state` for the duration of the launch.
  - `data = list(name = value)` — before recording starts, each value is
    stowed through the normal Slice 3/5 path (producing a content hash). The
    resulting `{name, hash}` is added to the pin map, so subsequent
    `grab(name)` inside the script returns exactly what was passed in.
- `R/grab.R` — consults the pin map (from `.mr_state`) before the default
  view lookup. Pinned hashes resolve via `_mr_versions`; pinned run ids
  resolve via `_mr_runs.outputs` and then `_mr_versions`.
- Launch cleanup clears the pin map on exit (success or error).

**Tests** (`test-pin-data.R`):

- Two launches of the same script with different `pin` values produce two
  runs with different `inputs` hashes and coexisting outputs addressable via
  `from_run`.
- `launch("s.R", data = list(p = df1))` makes `grab("p")` inside the script
  return `df1`.
- The xgboost-style loop from the design doc runs as written and yields
  three coexisting `predictions` versions.
- `pin` with a non-existent hash errors *before* `source()` is called — no
  partial run row is left behind in a bad state.
- `pin` and `data` together: `data` is applied first, `pin` wins on name
  collisions (document this choice in the function roxygen).

**Open question surfaced.** What if a script passed `data = list(p = df)`
*also* calls `stow("p", …)`? Is that (a) an error, (b) a new version
recorded normally, or (c) a silent overwrite of the pinned value for later
grabs within the same launch? Plan direction: (b), recorded normally.
Flagged in design.md for revisit after the first real sweep.

**Ship check.** The design doc's xgboost sweep example runs as-written.

---

## Slice 10 — Staleness diagnostics

**Goal.** Tell the user which steps are stale without auto-skipping anything.
Advisory only, as the design explicitly requires.

**Files built.**

- `R/staleness.R` — internal `.mr_is_stale(step)` returning
  `list(stale = TRUE/FALSE, reasons = character())`. Logic:
  1. Most recent `_mr_runs` row for `step`. None → `stale, "never_run"`.
  2. Current `code_hash` (script + helpers). Differs from recorded →
     `"code"`.
  3. For each recorded input `{name, hash_at_run_time}`, compare to the
     current latest hash for `name`. Differs → `"input:<name>"`.
  4. For each recorded external input, recompute hash. Differs →
     `"external:<key>"`.
- `R/launch.R` — just before running, compute staleness for the target step
  and emit an informational `message()` summarizing state. Does **not** skip
  — running is always the default.
- Exported `stale_steps()` (optional, include if small): returns a data frame
  of stale steps across all known step paths in `_mr_runs`. If this balloons,
  split to a follow-up slice.

**Tests** (`test-staleness.R`):

- Never-run step → `stale`, reason `"never_run"`.
- Edited script → stale, reason `"code"` on the next launch.
- Upstream rerun producing a different hash → downstream stale with reason
  `"input:<name>"`.
- Touching a declared external file → stale with reason `"external:<path>"`.
- Unchanged code + unchanged inputs + unchanged externals → fresh.
- Branchy script: running a different branch on rerun doesn't retroactively
  flag the prior run — staleness is evaluated against the *most recent* run,
  as the design requires.

**Design decision locked by this slice.** The design flags as an open
question whether "input changed" means (i) upstream `run_id` is newer or
(ii) upstream output hash differs. This plan commits to (ii), the stricter
rule — a newer run that produced the *same* hash should not mark downstream
stale. If the stricter rule causes pain in real use, the design can relax.

**Ship check.** A single script re-launched without changes reports
`fresh`; edit the script and re-launch reports `stale: code`.

---

## Slice 11 — `prune_versions()` + version-count warnings

**Goal.** Cleanup tooling. Ships last because it depends only on versioning
+ runs being in place, and because testing it against a realistic history
benefits from having the rest of the package working first.

**Files built.**

- `R/stow.R` — after a successful insert, count `_mr_versions` rows for this
  `logical_name`; if above
  `getOption("modelrunnR.version_warn_threshold", 20)`, `warning()` the user
  to consider `prune_versions()`.
- `R/launch.R` — at launch end, check the same threshold across every name
  this launch wrote. One warning per launch, not per write.
- `R/prune_versions.R` — exported
  `prune_versions(name = NULL, keep = NULL, keep_latest = FALSE, older_than = NULL, force = FALSE)`:
  1. Determine candidate versions: all `_mr_versions` rows, or filtered to
     `name`.
  2. Build the protected set: versions referenced in any `_mr_runs.outputs`
     JSON. (Current scope: all non-pruned runs — see open question below.)
  3. Apply policy filters in order: `keep_latest`, then `keep = N`, then
     `older_than`.
  4. If `force = FALSE`, subtract the protected set from prunable candidates
     and `warning()` once with the count of protected versions.
  5. For each prunable version: `DROP TABLE` the physical table (for
     tables), or delete the `_mr_artifacts` row / unlink the filesystem file
     (for artifacts). Then delete the `_mr_versions` row.
- `R/grab.R` — when `from_run` selects a version whose physical storage has
  been pruned, error clearly ("version `<hash>` for `<name>` has been
  pruned").

**Tests** (`test-prune.R`, `test-version-warning.R`):

- 21 stows of the same name emit the threshold warning once.
- `prune_versions("x", keep = 3)` leaves the three most recent; physical
  tables for the pruned ones are gone; `_mr_versions` rows are gone.
- A version referenced by a run is protected from pruning without
  `force = TRUE`.
- `force = TRUE` overrides protection; subsequent `grab(from_run = …)` for
  the pruned version errors clearly.
- `older_than = "1d"` prunes by `first_seen` age.
- `keep_latest = TRUE` keeps only the current view target per name.
- Prune removes both BLOB rows and filesystem artifact files.

**Open question surfaced.** What counts as "recent run records" for
protection purposes? Currently: all non-pruned runs. Candidates: last N,
younger-than-T, or an explicit retention policy. Flagged in design.md.

**Ship check.** A stow-heavy test DB can be shrunk back to a normal size
without losing the current version of anything.

---

## Open questions flagged during planning

The following were not in the design doc and are being appended to
`docs/design.md` §*Open questions*:

1. **`data`/`pin` + script `stow()` collisions.** If `data = list(p = df)`
   and the script also calls `stow("p", …)`, what semantics apply? Plan
   direction: record a new version normally. Surfaced in Slice 9.
2. **Scope of "recent run records" protecting versions from GC.** Currently
   all non-pruned runs; alternatives include last N, younger-than-T, or an
   explicit retention policy. Surfaced in Slice 11.
3. **Staleness rule for input changes.** Design flags this as open; plan
   commits to "content hash must differ," not "upstream run is newer."
   Locked in Slice 10 pending real-world pain signals.

## Explicitly out of scope for v0.1

Consistent with design.md §*Out of scope*, none of the following appear in
any slice:

- `launch_all()` / multi-script orchestration / rerun-downstream semantics
- `forget_step()` / `run_status()` / `run_history()` / drop APIs (design
  flags the shape of a "manage runs" API as an open question)
- Timing decomposition (DB vs user code) — v0.1 reports wall clock only
- Python model invocation
- MLflow-style metrics/registry tracking
- Experiment reporting, feature-engineering primitives, model-spec framework
- Transactional SQL backends
