# Append-mode `stow()` for tabular data

**Status:** design, drafted 2026-04-22
**Scope:** `stow()` dispatch change, new `_mr_append_tables` registry, new `grab()` selectors (`run =`, extended `variant =`), lossless schema-drift reconciliation, internal-only `.mr_reset_append()` helper.
**Depends on:** lazy-grab (grab returns lazy tbl), existing `_mr_runs` + variant_label machinery. Coexists with batch-launch and launch-sql without new interaction surface.

**Non-goals / deferred:** CRAN prep, remote executors, migration for in-the-wild DuckDB stores (clean break — see §10).

## Motivation

Today every `stow(df, "metrics")` call creates a new *version* under a fresh `metrics__<hash>` physical table. Running 20 models produces 20 disjoint one-row versions and `grab("metrics")` returns only the last. What users actually want is one 20-row table they can analyze across runs.

The versioning model is right for artifacts, views, and `ingest()`-style reference data — immutable stored values that need reproducibility, rebind-by-hash, and time-travel. It's wrong for per-run tabular outputs, which are fundamentally accumulating streams indexed by run.

Forcing both into one registry is why the current behavior surprises users. The fix is to name the two contracts separately: versions stay for immutable values; append tables get a parallel registry shaped around runs.

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

# One 3-row table, sliceable by run.
grab("metrics", run = "all") |> collect()
#> # A tibble: 3 × 5
#>   model rmse    r2  run_id   variant_label
#>   <chr> <dbl> <dbl> <chr>    <chr>
#> 1 lm    ...   ...   r_…      lm
#> 2 rf    ...   ...   r_…      rf
#> 3 gbm   ...   ...   r_…      gbm

# Default "just the latest run" still works for per-run outputs
# (predictions, a fitted model's scores, etc.) — see §5.
```

The mental model: "there is one `metrics` table; it grows with runs." No per-version physical tables; no `map_dfr(versions, grab)` glue.

## 1. Two-registry contract

The registry of **immutable stored values** stays as `_mr_versions` with `kind ∈ {table, view, artifact, lazy}`. Reproducibility, rebind-by-hash, `as_of`, dedup, and prune semantics stay crisp for those kinds.

A parallel registry tracks **accumulators** — one logical name, one physical table, grows with runs. It lives in a new table:

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

Cross-registry name collision (same `logical_name` appearing in both) is an error; `.mr_guard_namespace()` extends to cover this.

grab() dispatches on which registry holds the name.

## 2. `stow()` dispatch

```
stow(value, name)
  ├─ is.data.frame(value) || inherits(value, "tbl_lazy")  → append path (§3)
  └─ otherwise                                              → artifact path (unchanged)
```

The data-frame/lazy-tbl branch unconditionally goes to append. There is no versioned-tabular kind anymore under the new contract; users who want a one-shot immutable tabular value should use an artifact (`stow(as.list(df), "snapshot")`) or rely on the append table's `run_id` filter.

Lazy-tbl stow materializes server-side via `INSERT INTO <physical> SELECT * FROM (<lazy body>)`, same shape as eager stow — no special path.

**`ingest()` is unchanged.** `ingest()` loads reference data (CSVs, parquet) into a versioned `kind = "table"` row in `_mr_versions` — it's for immutable source data, not per-run outputs. Only `stow()`'s data-frame / lazy-tbl path changes.

## 3. Physical table shape

The growing table carries two system-injected columns alongside the user's:

```
<user columns...>, _mr_run_id TEXT, _mr_variant_label TEXT
```

Leading-underscore names follow the package's existing `_mr_*` convention. `stow()` errors **before writing anything** if the user's data frame already has a column named `_mr_run_id` or `_mr_variant_label` — caught at the schema check in §6, well before any row is touched, so no work is at risk.

First call on a name creates the physical table with these columns appended. Subsequent calls insert rows, filling both system columns from the current run's identifiers.

`physical_name` convention: `<logical>__append` (distinct from versioned `<logical>__<hash>`). A name containing unusual characters gets the same sanitization as today's versioned tables.

Wrap physical insert + registry update in one DuckDB transaction — matches how `stow()` already handles atomicity for versioned kinds.

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

```r
grab(name)                     # latest run, scoped to calling launch's variant (§5.1)
grab(name, run = "all")        # entire table
grab(name, run = run_id)       # one specific run
grab(name, variant = "fast")   # latest run with that variant_label
```

Return type: lazy tbl (matches the post-lazy-grab world). System columns `_mr_run_id` / `_mr_variant_label` are **stripped by default**. For `run = "all"` they surface as user-friendly `run_id` and `variant_label` columns (non-underscored).

### 5.1 Variant scoping

- Inside `launch(..., label = X)` → default = latest run with `_mr_variant_label = X`.
- Inside `launch()` with no explicit label, or called outside any `launch()` → default = latest run globally.

Matches how versioned grab already scopes by variant; no new rule, just extended.

### 5.2 Single-row hint

When `grab(name)` with default scoping returns **exactly one row** AND the table contains rows from more than one run, emit one informational message:

```
grab('metrics'): returned 1 row from 1 run (N more runs available).
  Use `run = 'all'` for the full history.
```

Gated by `options(modelrunnR.append_grab_hint = TRUE)` (on by default). The "one row" trigger — not "subset of total" — is deliberate: when users hit this, they almost always meant to get the accumulated table and didn't realize they'd only pulled the latest row. Multi-row per-run outputs (e.g. predictions) don't trip the hint.

## 6. Staleness and run-transaction semantics

Driven by the existing launch() machinery — code hash + input hashes + external inputs. No new staleness logic for appended contents.

- **`skipped_fresh` runs do not append.** The block never executes; no rows.
- **Failed runs roll back.** `stow()` uses transactions; a crash mid-block leaves the growing table in its pre-run state. Partial appends are impossible.
- **Re-run of a previously successful `run_id` — not a thing.** Each re-execution is a fresh run with a fresh id. No dedup needed.
- **Failed-then-retried runs produce two `_mr_runs` rows.** First has `status = error` and contributed zero rows; retry is a new run id with its own rows.

## 7. Composition with rebind / variants / prune

Inside `launch(..., rebind = list(x = ...))`, each ref kind behaves as follows when `x` resolves to an append table:

- **`mr_run(id)`** — subsequent `grab("x")` inside the block filters rows to that `run_id`.
- **`mr_variant(label)`** — `grab("x")` filters rows to the latest run with that variant.
- **`mr_as_of(ts)`** — rows from runs with `started_at ≤ ts`, then the usual "latest run" default collapses to the last run before `ts`.
- **`mr_hash("abc")`** — **errors**: "mr_hash() addresses immutable values; 'x' is an append table. Use mr_run() or mr_variant()." The per-chunk hashes stored in `_mr_runs.outputs` aren't a user-facing handle, and exposing them would pretend append tables are versioned when they aren't.

`prune_versions()` extends: for append tables, prunes rows (not whole tables) by `run_id` / `older_than`. Variant protection carries over — rows with a non-null `_mr_variant_label` are protected unless `force = TRUE`. Dropping all rows for a logical name does **not** drop the `_mr_append_tables` registry row; the accumulator exists even when empty.

Consider extracting a `prune_runs()` separate entry point if `prune_versions()`'s signature can't cleanly express the two contracts. **To decide in implementation.**

## 8. Provenance: `_mr_runs.outputs`

For append-mode stows, each run's `outputs` JSON records one entry per logical name appended:

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

Not a user-facing export in v1. If demand emerges, promote to `reset_append()` or fold into `prune_versions(drop_logical = TRUE)`. **Deferred.**

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
| Name collision with `_mr_versions` | Error | Contract ambiguity |
| `mr_hash()` rebind on append name | Error | Append tables aren't content-addressable |
| Crash mid-block | Full rollback via transaction | Atomicity |

The only `stop()` conditions are pre-insert — a run that reaches a `stow()` call can always save its work.

## Open follow-ups (flagged, not decided)

- Exact type-conflict strategy: §4.1 (a) coerce-to-TEXT vs (b) overflow table.
- Whether `prune_versions()` can cleanly express both versioned and append contracts or needs a sibling `prune_runs()`.
- `schema_json` column-order preservation and case sensitivity — implementation detail; punt until first test reveals what matters.
- If/when to promote `.mr_reset_append()` to user-facing.

## Invariants check

- **#2 (R CMD check passes):** no new `Imports:`.
- **#3 (spec primacy):** this is the spec.
- **#4 (schema migrations append-only):** only addition is `_mr_append_tables`; `_mr_versions` untouched.
- **#5 (exported API contract):** `stow()` and `grab()` signatures are unchanged at the R level — `grab()` gains new optional keyword arguments (`run =`), which is additive. Default-behavior change (tabular → append) is a breaking semantic change surfaced in NEWS.md.
- **#6 (no new Imports):** none proposed.
