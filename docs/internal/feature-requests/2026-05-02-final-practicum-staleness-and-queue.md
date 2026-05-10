# Feature requests: lazy-stow staleness and `queue()` dedupe

**Surfaced:** 2026-05-02 (from rendering `final_practicum/qmd/concurrent_price.qmd`)

**Context.** Three back-to-back renders of the same qmd, no source edits
between renders, no input file changes. Most launches behave correctly:
`rolling_windows`, `cprice_target`, and the two materialized panel
chunks all return `skipped_fresh` in 0 ms. Two failure modes show up
clearly against that backdrop — one bug and one missing feature.

---

## 1. Lazy-stow outputs never satisfy `skipped_fresh` (bug)

**Repro.** A `launch()` whose body produces a lazy dbplyr tbl and stows
it without `collect()` re-runs every render, even when no inputs changed.

```r
launch({
  sql_path <- grab("sql_path")
  grab("compustat_raw")
  sql <- sub(";\\s*$", "", paste(readLines(sql_path), collapse = "\n"))
  tbl(mr_con(), dbplyr::sql(sql)) |>           # <-- lazy
    stow(tools::file_path_sans_ext(basename(sql_path)))
}, rebind = list(sql_path = "SQL/feature_set__pure_fundamentals.sql"),
   external_inputs = list(files = "SQL/feature_set__pure_fundamentals.sql"),
   label = "build_features")
```

**Evidence.** Two consecutive renders of the same qmd with zero source
edits and zero input changes:

| render | variant_label    | status        | duration_ms |
|--------|------------------|---------------|-------------|
| 1      | `build_features` | `success`     | 14682       |
| 2      | `build_features` | `success`     | 7416        |

Sibling chunks in the same renders that use the **materialized** path
(`... |> collect() |> stow(...)`) all came back `skipped_fresh` in 0 ms,
including chunks whose launch body had been edited (comments added).
So the staleness logic is fine for materialized stows — it's
specifically lazy stow that misses.

**Hypothesis.** The lazy-stow path likely doesn't compute or persist a
stable content hash on the output, so `is_stale()` can't bind a prior
success to "this body+inputs produces this result." Either the lazy
path needs to compute a content hash post-execution and persist it the
way the materialized path does, or staleness should fall back to a
body-and-inputs equivalence (ignoring output) for lazy stows.

**User-side workaround.** Force a `collect()` before `stow()`,
accepting the materialization cost. For `build_features` that's billions
of rows (50 GB / 100 GB per the active append tables), so the workaround
is expensive — hence the request.

---

## 2. `queue()` does not dedupe — backlog grows every render (feature)

**Repro.** Each render of a qmd containing fanned-out `queue()` calls
appends a fresh copy of every queued row, even when body + rebind +
external inputs are byte-identical to existing queued rows.

**Evidence.** Three renders of `concurrent_price.qmd` with no source
changes between them:

| state            | total `queued`  |
|------------------|----------------:|
| baseline         | 1074            |
| after render 1   | 2787 (+1713)    |
| after render 2   | 3357 (+570)     |

The diminishing increment between renders 1 and 2 suggests *some* dedupe
logic exists (or some queue calls produce identical hashes), but most
queued rows duplicate freely.

**Ask.** `queue()` should match `launch()`'s skipped-fresh semantics:
if a `(body_hash, rebind_hash, external_inputs_hash)` already exists as
`queued` *or* as `success`/`skipped_fresh`, the new call should
short-circuit (register as `skipped_fresh`, or no-op) instead of
appending a duplicate `queued` row. This makes re-rendering idempotent.

---

## 3. No public API to clear queued runs (small feature)

There's no exported function for queue cleanup. `prune()` and
`prune_variants()` target stowed outputs, not run rows. Suggest one of:

- `discard_queued()` — clears all `queued` rows
- `discard_queued(variant_label = ...)` / `discard_queued(before = ...)`
  — filtered cull
- Or extend `prune()` with a `status =` arg

**User-side workaround:**

```r
DBI::dbExecute(mr_con(), "DELETE FROM _mr_runs WHERE status = 'queued'")
```

(Used in the practicum to cull 3357 stale queued rows after the renders
above.)

---

## Priority

1. **Lazy-stow staleness** — biggest. Every render of the canonical
   report rebuilds two billion-row feature tables for no reason
   (~30 s wall-clock plus DuckDB churn).
2. **`queue()` dedupe** — quality-of-life; compounds with #1 because
   each render also adds ~1700 dead queue rows.
3. **`discard_queued()` helper** — 10 lines; just wraps the workaround.
