# Append-mode `stow()` for tabular data

**Status:** design, drafted 2026-04-22, revised 2026-04-22 (shape-oriented reframing)
**Scope:** `stow()` dispatch change, new run-indexed storage shape, `grab()` default rule that depends on launch context, lossless schema-drift reconciliation, internal-only `.mr_reset_append()` helper, unified internal shape modules.
**Depends on:** lazy-grab (grab returns lazy tbl), existing `_mr_runs` + variant_label machinery. Coexists with batch-launch and launch-sql without new interaction surface.

**Non-goals / deferred:** CRAN prep, remote executors, migration for in-the-wild DuckDB stores (clean break — see §10).

## Changes from first draft (2026-04-22 → 2026-04-22 rev)

- **Reframed around storage shapes, not registries.** The organizing concept is the physical layout each logical name needs (content-addressed immutable vs. run-indexed accumulator). Registries (`_mr_versions`, `_mr_append_tables`) are bookkeeping for the two shapes; they don't drive the design.
- **Cleaner `grab()` default rule.** Inside an active `launch()`, a Shape B `grab(name)` returns the current run's rows. Outside `launch()`, it returns the full table. The previous draft's "single-row hint" (§5.2) is dropped — the rule it was warning about is gone.
- **Internal API is re-sketched around shapes, not verbs** (§12). `stow.R` and `grab.R` become thin dispatchers; the hard work lives in `shape_versioned.R` and `shape_append.R`.
- **Prune is unified internally; exports are unchanged.** `prune_versions()` stays exported (invariant 5); a new `prune_runs()` export handles Shape B. Both call a shared internal `.mr_prune(by = ...)`.

## Amendments 2026-04-23 (rev 3 — shape-invisibility principle)

Organizing principle going forward: **shapes should be invisible to the user.** The two storage shapes are an internals concern; a user shouldn't need to know which shape a logical name is in to decide which function to call. All user-facing operations should work on both shapes (with sensibly different *meaning*, but identical calls and — where possible — identical return schemas). Earlier amendments (option Y: `versions()` / `mr_hash()` extended to Shape B) were instances of this principle; this rev names it and closes the remaining gaps.

Concrete decisions from this pass:

- **One unified `prune()` export (shape axis).** Replaces the split `prune_versions()` + planned `prune_runs()` with a single `prune(name, by = c("version", "run", "age"), older_than = ..., keep = ..., keep_latest = ..., force = ...)` that dispatches on the name's shape. Invalid `by` for the resolved shape errors clearly (`by = "version"` on a Shape B name, etc.); `by = "age"` works on both. Internal `.mr_prune()` stays (§12). **`prune_variants()` is out of scope** of this unification — variants are a separate axis from shape, so that export is unaffected. **Invariant 5 impact:** `prune_versions()` is a pre-existing export on `main`; removal is authorized in conversation (2026-04-23). No deprecation shim — pre-1.0.
- **`grab(name, run = "all")` is meaningful on both shapes.** On Shape B it already stacks all runs' rows with `run_id` / `variant_label` surfaced (existing §5.2). On Shape A it returns a **list** of versions (one element per version, in `versions()` row order), with each element the materialized value and names taken from `content_hash`. Makes the cross-history knob work regardless of shape, at the cost of Shape A returning a list rather than a tbl — acceptable because the user asked for "all" on an inherently non-tbl-shaped history.
- **`versions()` ordering is latest-first for both shapes.** Shape A currently returns ascending; changed to descending by `first_seen` (and `created_at` where that's the per-row timestamp) to match Shape B. Rd docs and any callers that indexed `[1]` expecting oldest are updated. Closes `TODO.md`'s "versions() row ordering inconsistent" item.

Downstream spec sections to re-read under this principle:
- §5 (`grab()` semantics) — `run = "all"` Shape A behavior is the new addition.
- §7 (composition with rebind / variants / prune) — "Prune" bullet list is superseded by the unified export above.
- §12 (internal API sketch) — `prune.R`'s exported entry point is now `prune()` not `prune_versions()` / `prune_runs()`; `.mr_prune(by = ...)` is unchanged.

## Motivation

Today every `stow(df, "metrics")` call creates a new *version* under a fresh `metrics__<hash>` physical table. Running 20 models produces 20 disjoint one-row versions and `grab("metrics")` returns only the last. What users actually want is one 20-row table they can analyze across runs.

Under the hood there are two different *storage shapes* hiding behind one API:

- **Shape A — content-addressed store.** One physical table (or blob) per distinct value. Identity is the content hash. Two runs producing the same value share the table. Used for ingested reference data, artifacts, views.
- **Shape B — run-indexed append log.** One physical table per logical name. Rows tagged with `run_id` (and `variant_label`). Identity is the run that wrote the row. No dedup; ordering by run is the point.

Versioning (Shape A) is right for immutable stored values that need reproducibility, rebind-by-hash, and time-travel. It's wrong for per-run tabular outputs, which are fundamentally accumulating streams indexed by run. Naming the two shapes separately is what makes the surprising cases (per-run metrics, sweep results) become obvious.

## Target vignette snippet (what success looks like)

```r
library(modelrunnR)
library(dplyr)

# A sweep across three models.
launch({
  dat <- grab("training") |> collect()
  fit <- lm(y ~ ., data = dat)

  tibble(
    model = "lm",
    rmse  = sqrt(mean(resid(fit)^2)),
    r2    = summary(fit)$r.squared
  ) |> stow("metrics")
}, label = "lm")

launch({ ... }, label = "rf")   # appends a row for random forest
launch({ ... }, label = "gbm")  # appends a row for gradient boost

# Outside any launch, grab() returns the whole table.
grab("metrics") |> collect()
#> # A tibble: 3 × 5
#>   model rmse    r2  run_id   variant_label
#>   <chr> <dbl> <dbl> <chr>    <chr>
#> 1 lm    ...   ...   r_…      lm
#> 2 rf    ...   ...   r_…      rf
#> 3 gbm   ...   ...   r_…      gbm
```

The mental model: "there is one `metrics` table; it grows with runs." No per-version physical tables; no `map_dfr(versions, grab)` glue.

## 1. Storage shapes

Every logical name in the store has exactly one shape, fixed the first time it's written.

### Shape A — content-addressed

- Bookkeeping table: `_mr_versions` (unchanged).
- Kinds: `table` (ingested tabular reference data), `view`, `artifact`, `lazy`.
- Identity: `(logical_name, content_hash)`. Physical: `<logical>__<hash>` per distinct value.
- Contract: immutable. Reproducibility via rebind-by-hash, `mr_as_of()`, dedup across runs.

### Shape B — run-indexed append log

- Bookkeeping table: new `_mr_append_tables`.
- Kinds: just one — the accumulator.
- Identity: `(logical_name, run_id)` at the row level. Physical: one table, `<logical>__append`.
- Contract: grows with runs; rows stamped with system columns; schema reconciles losslessly across runs.

```sql
CREATE TABLE _mr_append_tables (
  logical_name   TEXT PRIMARY KEY,
  physical_name  TEXT NOT NULL,
  schema_json    TEXT,         -- {colname: duckdb_type} of current user-facing columns
  first_seen     TIMESTAMP,
  last_seen      TIMESTAMP,
  row_count      BIGINT,
  size_bytes     BIGINT
)
```

Cross-shape name collision (same `logical_name` appearing in both `_mr_versions` and `_mr_append_tables`) is an error; `.mr_guard_namespace()` extends to cover this.

## 2. `stow()` dispatch

```
stow(value, name)
  ├─ is.data.frame(value) || inherits(value, "tbl_lazy")  → Shape B (append)
  └─ otherwise                                              → Shape A (artifact)
```

The data-frame / lazy-tbl branch unconditionally goes to Shape B. There is no versioned-tabular kind under the new contract; users who want a one-shot immutable tabular value should use an artifact (`stow(as.list(df), "snapshot")`) or rely on Shape B's `run_id` filter.

> **Amendment 2026-04-23 (option Y).** The original draft said Shape B has no content-hash identity — but the chunk_hash computed per append already functions as one, at the *chunk level* (one run's contribution = one "version"). This spec's §5 / §6 originally disallowed `versions()` and `mr_hash()` on Shape B names; in practice the `batch-launches.Rmd` SQL-batch example relied on exactly those, so the implementation now surfaces per-append chunk_hashes as versions and lets `mr_hash()` resolve against them. See "Amendment §5 / §6" below.

Lazy-tbl stow materializes server-side via `INSERT INTO <physical> SELECT * FROM (<lazy body>)`, same shape as eager stow — no special path.

**`ingest()` is unchanged.** `ingest()` loads reference data into Shape A (`kind = "table"` in `_mr_versions`) — it's for immutable source data, not per-run outputs. Only `stow()`'s data-frame / lazy-tbl path changes.

## 3. Physical table shape (Shape B)

The growing table carries two system-injected columns alongside the user's:

```
<user columns...>, _mr_run_id TEXT, _mr_variant_label TEXT
```

Leading-underscore names follow the package's existing `_mr_*` convention. `stow()` errors **before writing anything** if the user's data frame already has a column named `_mr_run_id` or `_mr_variant_label` — caught at the schema check in §4, well before any row is touched, so no work is at risk.

First call on a name creates the physical table with these columns appended. Subsequent calls insert rows, filling both system columns from the current run's identifiers.

`physical_name` convention: `<logical>__append` (distinct from Shape A's `<logical>__<hash>`). A name containing unusual characters gets the same sanitization as today's versioned tables.

Wrap physical insert + registry update in one DuckDB transaction — matches how `stow()` already handles atomicity for Shape A kinds.

## 4. Schema drift — lossless reconciliation

**Design constraint:** `stow()` cannot lose the user's work. A run may be an hour of compute; a schema mismatch must not raise and discard the result.

On every append after the first, compare the incoming frame's columns against `schema_json`:

| Case | Action | Signal |
|---|---|---|
| **Incoming adds columns** | `ALTER TABLE ADD COLUMN` for each new column (typed from the incoming value); backfill prior rows as NULL; extend `schema_json`. Insert row. | `warning()`: "stow('metrics'): extending schema with new columns: mae, r2" |
| **Incoming drops columns** | Insert with the missing columns as NULL. No schema change. | `message()`: "stow('metrics'): incoming data missing columns 'mae'; inserted as NULL" |
| **Type conflict** (same column, different type) | See §4.1. The user's data is preserved no matter what. | `warning()` explaining what was done. |
| **System-column conflict** (`_mr_run_id` / `_mr_variant_label` already in user's frame) | Error **before** any write — caught at schema check, nothing stow'd yet, no data at risk. | `stop()`: "stow('metrics'): column '_mr_run_id' is reserved; rename before stowing." |

### 4.1 Type conflict — open design question

Two candidates, both lossless:

- **(a) Coerce column to TEXT.** On type mismatch for column C, cast both existing rows' C and incoming C to TEXT; update `schema_json` to record C's new type. Semantics degrade (numeric becomes string) but values survive. Users can reset with `.mr_reset_append()` (§9) once they realize.
- **(b) Overflow table.** On type mismatch, append incoming row to a side table `<logical>__append_overflow` with a loud warning pointing at it. Main table stays clean for prior rows' type.

**To decide in implementation** — both are tolerable for v1. Defaulting to (a) for simplicity unless implementation reveals a reason otherwise. Flagged in the follow-ups list below.

Insertion uses an explicit `INSERT INTO <physical> (<cols>) SELECT ...` so column mapping is unambiguous regardless of input column order.

## 5. `grab()` semantics

### 5.1 Shape dispatch

`grab(name)` first looks `name` up in the namespace (§1) and dispatches by shape. Shape A semantics are unchanged from today. What follows governs Shape B.

### 5.2 Default rule (Shape B)

**Revised 2026-04-23.** Default returns one coherent single-run snapshot, not the full accumulator — the exploratory `grab("metrics") |> collect()` workflow should look like any other `grab()`, not force-dump every prior run as input. The full-history view is an explicit opt-in.

| Context | Default | Rationale |
|---|---|---|
| Inside `launch()` (any label or none) | Current run's rows only (`_mr_run_id = <this run>`) | A running step reading its own accumulator wants "what I'm building now", not the whole history. |
| Outside `launch()` (e.g. at the REPL, post-sweep analysis) | Latest run's rows only (most recent `started_at` among runs that wrote `name`) | Exploratory reads want a clean snapshot. Pulling the full accumulator as input stacks prior runs' rows into downstream work — usually not desired. Inspecting history is its own workflow. |

Explicit args override the default:

```r
grab(name)                     # default: single-run snapshot per table above
grab(name, run = "all")        # full cross-run view (explicit)
grab(name, run = run_id)       # one specific run
grab(name, variant = "fast")   # latest run with that variant_label
```

Return type: lazy tbl (matches the post-lazy-grab world). System columns `_mr_run_id` / `_mr_variant_label` are **stripped** on every single-run result (default and explicit). On the `run = "all"` cross-run view they **surface** as user-friendly `run_id` and `variant_label` columns (non-underscored).

**Dropped from prior draft:** the `options(modelrunnR.append_grab_hint)` single-row hint. With the rule above, the "why did I only get one row" failure mode doesn't occur at the REPL (default is "all"), and inside `launch()` a one-row default is what the user is actively asking for.

> **Amendment 2026-04-23 (option Y).** `versions(name)` was originally scoped to Shape A only; implementation now returns one row per appended chunk for Shape B names, reading from `_mr_runs.outputs` entries with `kind = "append_table"`. `content_hash` on each row is the chunk_hash; `produced_by_runs` lists the producing run_id. This makes `versions()` + `mr_hash()` round-trip through Shape B, matching the `batch-launches.Rmd` SQL-batch pattern. Ordering for Shape B is latest-first (divergent from Shape A's ascending — tracked in `TODO.md`).

> **Amendment 2026-04-23 (interactive writes for Shape B).** `stow(df, name)` and `stow(<lazy tbl>, name)` outside `launch()` no longer error. Implementation mints an `<interactive:TS>` `_mr_runs` row with `status = "interactive"` (matching the Shape A / `ingest()` convention in `R/interactive.R`) and stamps appended rows with that synthetic run_id. Downstream launches that `grab()` an interactively-stowed value get the same reproducibility warning already emitted for artifact / ingest inputs. This preserves grab's "latest run" rule without requiring users to wrap one-off stows in an empty `launch({})`.

## 6. Staleness and run-transaction semantics

Driven by the existing launch() machinery — code hash + input hashes + external inputs. No new staleness logic for Shape B contents.

- **`skipped_fresh` runs do not append.** The block never executes; no rows.
- **Failed runs roll back.** `stow()` uses transactions; a crash mid-block leaves the growing table in its pre-run state. Partial appends are impossible.
- **Re-run of a previously successful `run_id` — not a thing.** Each re-execution is a fresh run with a fresh id. No dedup needed.
- **Failed-then-retried runs produce two `_mr_runs` rows.** First has `status = error` and contributed zero rows; retry is a new run id with its own rows.

## 7. Composition with rebind / variants / prune

Inside `launch(..., rebind = list(x = ...))`, each ref kind behaves as follows when `x` resolves to a Shape B name:

- **`mr_run(id)`** — subsequent `grab("x")` inside the block filters rows to that `run_id` (overrides the §5.2 default).
- **`mr_variant(label)`** — `grab("x")` filters rows to the latest run with that variant.
- **`mr_as_of(ts)`** — rows from runs with `started_at ≤ ts`, then the usual "latest run" default collapses to the last run before `ts`.
- **`mr_hash("abc")`** — ~~errors~~ **(amended 2026-04-23, option Y)** resolves against the chunk_hash of the run that appended that content. Lookup is against `_mr_runs.outputs` scanning for `kind = "append_table"` entries with matching `logical_name` + `chunk_hash`; the resolved run_id drives the same filter as `mr_run()`. Errors if the hash matches no chunk of this name.

Prune:

- `prune_versions()` stays exported, Shape A only (invariant 5 — existing signature is a contract).
- **New export `prune_runs()`** handles Shape B: prunes rows (not whole tables) by `run_id` / `older_than`. Variant protection carries over — rows with a non-null `_mr_variant_label` are protected unless `force = TRUE`. Dropping all rows for a logical name does **not** drop the `_mr_append_tables` registry row; the accumulator exists even when empty.
- Internally both dispatch into `.mr_prune(by = ...)` — see §12.

## 8. Provenance: `_mr_runs.outputs`

For Shape B stows, each run's `outputs` JSON records one entry per logical name appended:

```json
{
  "kind": "append_table",
  "logical_name": "metrics",
  "rows_appended": 1,
  "chunk_hash": "a1b2c3..."
}
```

`chunk_hash` is the content hash of the rows this run contributed, computed using the same row-order-independent hash as today's versioned tables. Not user-facing (per §7, `mr_hash()` doesn't accept it), but it enables internal diffing / audit queries.

## 9. Internal helper: `.mr_reset_append()`

When a user's schema has drifted enough that they want to wipe and restart a logical name, the mechanics are:

```r
# internal, not @export'd
.mr_reset_append(con, logical_name) {
  # DROP TABLE <physical>; DELETE FROM _mr_append_tables WHERE logical_name = ?
  # Leaves _mr_runs history intact — only the growing table is cleared.
}
```

Not a user-facing export in v1. If demand emerges, promote to `reset_append()` or fold into `prune_runs(drop_logical = TRUE)`. **Deferred.**

## 10. Migration

Clean break — this package has no production users beyond the maintainer, who can regenerate their stores.

- New `_mr_append_tables` table created idempotently on connect (existing migration path).
- No changes to `_mr_versions` schema (invariant #4 satisfied).
- Databases with legacy versioned tabular data continue to read (`grab(name, version = h)` still works) but new `stow(df, name)` with a legacy-versioned name on disk errors with a namespace clash — `.mr_guard_namespace()` catches it. The user can drop the legacy rows and re-stow.

## 11. Error handling summary

| Condition | Behavior | Why |
|---|---|---|
| Schema adds / drops columns | Warn / message; proceed | Never lose a run's work |
| Type conflict | Coerce to TEXT (or overflow table — §4.1); warn | Never lose a run's work |
| System column in user frame (`_mr_run_id` / `_mr_variant_label`) | Error before any insert | Caught pre-insert; user data still in memory |
| Name collision across shapes (A and B) | Error | Contract ambiguity |
| `mr_hash()` rebind on Shape B name | Error | Append logs aren't content-addressable |
| Crash mid-block | Full rollback via transaction | Atomicity |

The only `stop()` conditions are pre-insert — a run that reaches a `stow()` call can always save its work.

## 12. Internal API sketch

The current `R/` layout organizes by verb (`stow.R`, `grab.R`, `versions.R`). After this change, each verb branches on shape, which duplicates dispatch in every verb file. Reorganize so shape-specific work lives with the shape, and verbs stay thin:

```
R/
  shape_versioned.R   # Shape A: insert, lookup-by-hash, list, row-count,
                      # prune-by-lineage. Wraps _mr_versions.
  shape_append.R      # Shape B: ensure_table, reconcile_schema,
                      # append_rows (with system columns), query-by-run,
                      # prune-by-run. Wraps _mr_append_tables.
  namespace.R         # .mr_guard_namespace(): one name → one shape.
                      # .mr_lookup_shape(name) → "A" | "B" | NULL.
  stow.R              # Thin: classify value → pick shape → delegate.
  grab.R              # Thin: lookup shape → reader; arg parsing for
                      # run=/variant=/version=; launch-context detection
                      # for the §5.2 default rule.
  prune.R             # .mr_prune(by = c("run","variant","hash","age"))
                      # called by exported prune_versions() and prune_runs().
  schema.R            # unchanged — owns both _mr_versions and
                      # _mr_append_tables migrations.
```

Concretely, the restructure touches:

- `stow.R` (286 lines) → ~60 lines of dispatch + `shape_append.R` (new) + `shape_versioned.R` (extracted from existing code).
- `grab.R` (283 lines) → ~80 lines of dispatch + arg handling; readers move to shape modules.
- `versions.R` → folded into `shape_versioned.R`.
- `prune_versions.R` (261 lines) → keeps the exported entry point; implementation moves to `prune.R` + shape modules.

**Invariant check for this reorg:**

- Invariant 4 (schema append-only): file moves don't touch schema.
- Invariant 5 (exported API contract): `stow`, `grab`, `ingest`, `prune_versions`, rebind helpers — no signature changes. New exports: `prune_runs()` (additive). `grab()` gains optional `run =` arg (additive).
- Invariant 6 (no new Imports): none.

## Open follow-ups (flagged, not decided)

- Exact type-conflict strategy: §4.1 (a) coerce-to-TEXT vs (b) overflow table.
- `schema_json` column-order preservation and case sensitivity — implementation detail; punt until first test reveals what matters.
- If/when to promote `.mr_reset_append()` to user-facing.
- Launch-context detection for §5.2 — whether to key off the in-scope `run_id` binding or a dedicated flag set by `launch()`. Implementation detail, flagged so the decision is visible in the PR.

## Invariants check

- **#2 (R CMD check passes):** no new `Imports:`.
- **#3 (spec primacy):** this is the spec.
- **#4 (schema migrations append-only):** only addition is `_mr_append_tables`; `_mr_versions` untouched.
- **#5 (exported API contract):** `stow()` and `grab()` signatures are unchanged at the R level — `grab()` gains new optional keyword arguments (`run =`), additive. New export `prune_runs()` is additive. Default-behavior change (tabular → append) is a breaking semantic change surfaced in NEWS.md.
- **#6 (no new Imports):** none proposed.
