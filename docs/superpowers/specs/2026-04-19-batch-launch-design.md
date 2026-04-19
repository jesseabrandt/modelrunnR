# Batch launches via `rebind`

**Status:** design, approved 2026-04-19
**Scope:** `launch()` dispatch, new `on_error =` argument, new exports `mr_binds()`, `mr_variants()`, `mr_envelopes()`, new `_mr_runs.rebinds` column (applies to single launches too), vignette section.
**Depends on:** nothing new. Coexists with [lazy-grab](2026-04-17-lazy-grab-design.md) and [launch-sql](2026-04-18-launch-sql-design.md) — both operate at the single-run layer this spec wraps.

## Motivation

The practicum workflow hits hyperparameter sweeps (and variant fleets) constantly. Without package support users fall back to `for` loops around `launch()`, each iteration mutating a `rebind =` list. That pattern has three problems:

1. **No single-call record.** The loop is the user's code, not modelrunnR's, so there's no single provenance anchor tying the N runs together.
2. **Label discipline falls on the user.** Pasting `sprintf("%s_%d", ...)` labels into each iteration is noise.
3. **No expansion helpers.** `expand.grid()` / `purrr::cross()` / manual `Map()` are all available but none know about modelrunnR refs (`mr_variant()`, `mr_hash()`, etc.) or envelope structure.

The fix is small: make `launch()` fan out when given a list of rebind envelopes instead of a single one, and ship two thin constructors so users rarely have to hand-write the envelope list.

## Target vignette snippet (what success looks like)

```r
library(modelrunnR)

# 3 variants of features × 3 alphas = 9 runs, one call.
my_params <- mr_binds(
  features = mr_variants("clean", "sampled", "raw"),
  alpha    = c(0.1, 0.5, 1.0),
  mode     = "cross"
)

launch({
  x   <- grab("features") |> dplyr::collect()
  fit <- glmnet::glmnet(x[, -1], x$y, alpha = grab("alpha"))
  stow(fit, "model")
}, rebind = my_params)
#> modelrunnR: batch of 9 runs (cross: features × alpha)
#> ...
#> modelrunnR: 9/9 succeeded
```

The call returns a data frame with 9 rows — one per run — shaped like today's single-run return.

## API surface

Three new exported helpers (`mr_binds()`, `mr_variants()`, `mr_envelopes()`), one new `launch()` argument (`on_error =`), and a dispatch change inside `launch()`.

### `mr_binds(..., mode = "zip", .labels = NULL)`

Pure list constructor. Takes named `...` where each value is the sweep values for that rebind name. Returns a classed object (`mr_binds`) carrying the expanded envelope list.

- **`mode = "zip"`** (default): element-wise pairing. All `...` arguments must share one length N, or be length 1 (recycles to N). Errors on mismatched lengths.
- **`mode = "cross"`**: Cartesian product. N = product of lengths.
- **`.labels`**: optional character vector. Must be exactly length N after expansion. Each element becomes the `variant_label` for the corresponding run. When `NULL` (default), labels are left unset and the existing auto-propagation path fills them from upstream variants.

`mr_binds()` does not interpret values — each `...` slot is treated as an opaque vector/list. A value that's a modelrunnR ref (via `mr_variant()`, `mr_hash()`, `mr_run()`, `mr_as_of()`) flows through as a ref; a bare R value flows through as a bare value. Resolution happens later inside `launch()` via the existing `.mr_resolve_rebind_entry()` path.

### `mr_variants(...)`

Convenience vector of variant refs:

```r
mr_variants("clean", "sampled", "raw")
# identical to:
list(mr_variant("clean"), mr_variant("sampled"), mr_variant("raw"))
```

Accepts `...` as bare strings; returns a `list` of `mr_variant` refs. This is the only reason the helper exists — `mr_binds(features = c("clean", "sampled"))` would otherwise pass bare strings as literal values, not variant refs.

Sibling helpers `mr_hashes()` / `mr_runs()` / `mr_as_ofs()` are **out of scope** for this spec; ship them only if a concrete use case demands them.

### Hand-built envelopes (escape hatch)

Users who want per-envelope `.label` and per-envelope mixed refs can bypass `mr_binds()` and hand the classed object:

```r
mr_envelopes(
  list(.label = "baseline",    features = mr_variant("clean"),   alpha = 0.1),
  list(features = mr_variant("sampled"), alpha = 0.5),     # auto-propagated label
  list(.label = "raw_override", features = mr_variant("raw"), alpha = 1.0)
)
```

Where `mr_envelopes()` is the third exported constructor: takes `...` of named lists, validates each as an envelope (every name non-empty, `.label` optional-scalar-character), returns an `mr_binds` object. This is the primitive; `mr_binds()` is sugar on top.

### Dispatch inside `launch()`

`launch()` checks `rebind` before resolution:

1. `NULL` → no rebinds (current behavior).
2. Inherits `"mr_binds"` class → batch mode (this spec).
3. Named list → single envelope (current behavior).
4. Anything else → error with a pointer to `mr_binds()` / `mr_envelopes()`.

No shape-based dispatch. The class tag is the whole dispatch rule.

## Execution semantics

### Loop, not parallel

Batch runs **sequentially** inside the single `launch()` call. Each envelope goes through the full current single-run pipeline: resolve rebinds → write run row on entry/exit → staleness check → source or eval → record inputs/outputs. Parallel execution is out of scope for this spec; it can be layered later without changing the user-facing shape.

### Staleness and skip-on-fresh

Each envelope gets its own staleness check (different inputs → independent freshness). `force = TRUE` on the `launch()` call applies to every envelope in the batch. `options(modelrunnR.skip_if_fresh = FALSE)` behaves as today.

A batch of 9 where 3 are fresh and 6 are stale produces 9 run rows, 3 of status `skipped_fresh` and 6 of status `success` / `error`.

### Errors

Default is **run-all-then-raise**:

- Every envelope runs regardless of earlier failures.
- Each failure is captured on its own `_mr_runs` row with `status = "error"`.
- After all N complete, if any row has `status = "error"`, `launch()` raises a single `stop()` summarizing counts and pointing the user at the run rows.

Opt out via a new `launch()` argument:

```r
launch({...}, rebind = my_params, on_error = "warn")    # warning() at end instead of stop()
launch({...}, rebind = my_params, on_error = "raise")   # default
```

The returned data frame always contains all N rows regardless of `on_error`. `on_error = "silent"` is deliberately not provided — silent failure is the failure mode the package exists to prevent.

`on_error` is only meaningful in batch mode. When passed to a non-batch `launch()` it errors with `"launch(): on_error only applies when rebind = is an mr_binds() object."` — silently accepting it would hide the user's intent drift.

### Seed

`duckdb_seed =` is a scalar, applied identically to every envelope. Per-run seed variation goes through `mr_binds(seed = c(...))` as a sweep param and reaches the user's block through `grab("seed")`, not through `duckdb_seed`.

### Nested-launch guard

The existing nested-launch error (`launch()` refuses to run if `.mr_state` indicates an outer launch) stays. Batch mode drives the loop from outside the per-run `.mr_state` push/pop, so the guard only fires if user code *inside* an envelope calls `launch()` — which is the condition it was built to catch.

### Interactive-write suppression

Inside rebind resolution, the existing `.mr_state$suppress_interactive <- TRUE` path (see `R/rebind.R`) continues to apply per envelope. No change.

## Labels — the full rule

Two independent mechanisms, both available in both modes:

1. **Explicit (C).** Either `.labels = c(...)` on `mr_binds()` or `.label = "..."` inside a hand-built envelope. Validated at construction.
2. **Auto-propagation (D).** When an envelope carries no explicit label, the run enters the existing `.mr_propagate_label()` code path and inherits from its upstream variants. Identical behavior to today's single-launch auto-propagation.

Precedence: explicit beats auto. No mixing within one envelope (there's no slot for "partial" labels).

Auto-derived labels from sweep values (e.g. `"features=clean,alpha=0.1"`) were rejected — but for a less-obvious reason than "already recorded". They aren't currently recorded in readable form: `_mr_runs.inputs` stores `{name, hash}` pairs only, and bare-value rebinds write a hash of the stowed value with no trace of the literal. The real fix is the `_mr_runs.rebinds` provenance column (see below), not clobbering the label slot with a derived string.

## Rebind provenance on the run row

Today a run row records `inputs` as JSON pairs of `{name, hash}`. When a rebind was in play, the hash points either to an existing version (ref-based rebind) or to a just-stowed artifact (bare-value rebind). Neither case preserves the user-readable reason the hash was chosen — for variants you can join back through `_mr_versions`, but for literal values like `alpha = 0.5` there's no path back to "0.5" short of deserializing the artifact.

This spec adds a new `_mr_runs.rebinds` column (TEXT, JSON array) that records, per run, the resolved rebind map with source tags:

```json
[
  {"name": "features", "source": "variant", "value": "clean",    "hash": "abc123..."},
  {"name": "alpha",    "source": "literal", "value": "0.5",      "hash": "def456..."},
  {"name": "baseline", "source": "run",     "value": "run_2026...", "hash": "789..."}
]
```

`source` is one of:

| `source`  | when                              | `value` is                                    |
|-----------|-----------------------------------|-----------------------------------------------|
| `variant` | `mr_variant("clean")`             | the variant label string                      |
| `hash`    | `mr_hash("abc...")`               | the hash itself (full, not prefixed)          |
| `run`     | `mr_run("run_...")`               | the run id                                    |
| `as_of`   | `mr_as_of(<time>)`                | ISO timestamp                                 |
| `literal` | bare R value passed to `rebind =` | `format()` of scalar atomics; `"data.frame[<nrow>x<ncol>]"` for data frames; `"<class>[<size_bytes>B]"` for other R objects |

`value` is always a scalar string. `hash` is always the resolved content_hash (same one stored in `inputs`).

### When it's written

The rebinds JSON is produced inside `.mr_resolve_rebinds()` — alongside the existing resolution — and plumbed through `.mr_write_run_row()` to the new column. Single-launch runs and each batch-member run get the column populated identically.

Skipped-fresh runs (where the block doesn't execute) still write resolved rebinds, so a `skipped_fresh` row can answer "what would this run have bound to?" without re-running anything.

Runs with no rebinds (the common case today) write `"[]"`.

### Migration

New column added via `.mr_add_column_if_missing(con, "_mr_runs", "rebinds", "TEXT")`. Existing rows get `NULL` and stay readable. No backfill.

### User-facing surface

No new function. Users query the column directly via `mr_con()` or by reading `_mr_runs`. A helper (`rebinds(run_id)` or similar) is out of scope for this spec; add one when a concrete use case demands it.

## Return shape

`rbind()` of the single-run rows, preserving column types and order. For `nrow(envelopes) == 1`, the shape is byte-identical to today's single-run return.

Returned invisibly, matching current `launch()`.

## Relation to existing unimplemented specs

- **Lazy-grab:** Batch runs see the same lazy-`grab()` path as single runs; no interaction needed beyond reusing it. A batch of N runs where each does `grab("features") |> dplyr::collect()` just calls the lazy path N times.
- **Launch-SQL:** Same story — SQL steps are at the single-run layer. A batch of SQL launches is meaningful (`launch("features.sql", rebind = mr_binds(panel_raw = mr_variants("raw_v1", "raw_v2")))`) and falls out for free once both specs land.

## Relation to open TODOs

- **TODO 1 (`rebind` pollutes `_mr_versions`):** Unchanged by this spec. Whatever fix lands for bare-value rebind scoping applies per envelope automatically — `mr_binds()` does not create a new resolution path.
- **TODO 2 (lazy `tbl_dbi` stow):** Unrelated.
- **TODO 3 (stow signature-swap guard):** Unrelated.

## Vignette (feature guide)

This is the section that ships as a new H2 in `vignettes/getting-started.Rmd`, or (more likely) its own `vignettes/batch-launches.Rmd`. Final location decided at implementation time.

---

### Running a batch of launches

Most model work isn't one fit, it's *a sweep* — three features, three alphas, a few seeds. modelrunnR runs these as a batch from a single `launch()` call.

#### The helper

`mr_binds()` builds the sweep description. Each named argument is the vector of values for that rebind slot.

```r
my_params <- mr_binds(
  features = mr_variants("clean", "sampled", "raw"),
  alpha    = c(0.1, 0.5, 1.0),
  mode     = "zip"
)
```

`mode = "zip"` pairs values element-wise: three features, three alphas, three runs. Lengths must line up (length-1 recycles).

`mode = "cross"` takes the Cartesian product: 3 × 3 = 9 runs.

#### Running it

Hand the result to `rebind =`:

```r
launch({
  x   <- grab("features") |> dplyr::collect()
  fit <- glmnet::glmnet(x[, -1], x$y, alpha = grab("alpha"))
  stow(fit, "model")
}, rebind = my_params)
```

You get one run row per envelope. The returned data frame has `N` rows, identical in shape to the single-run return.

#### Labels

Two ways to label the runs:

```r
# Explicit
mr_binds(features = mr_variants("clean","sampled","raw"),
         alpha    = c(0.1, 0.5, 1.0),
         mode     = "zip",
         .labels  = c("baseline", "smoke_test", "raw_ridge"))
```

```r
# Let auto-propagation label from the upstream variants
mr_binds(features = mr_variants("clean","sampled","raw"),
         alpha    = c(0.1, 0.5, 1.0),
         mode     = "zip")
# each run inherits its label from the `features` variant it used
```

For hand-picked labels on some envelopes but not others, drop down to `mr_envelopes()`:

```r
mr_envelopes(
  list(.label = "baseline",    features = mr_variant("clean"),   alpha = 0.1),
  list(features = mr_variant("sampled"), alpha = 0.5),
  list(.label = "raw_override", features = mr_variant("raw"),    alpha = 1.0)
)
```

#### Errors

By default, a batch runs to completion and raises a single error at the end summarizing any failed runs. Each failure is still captured in `_mr_runs` with `status = "error"`. To demote the final error to a warning:

```r
launch({...}, rebind = my_params, on_error = "warn")
```

You always get every row back, regardless of how individual runs fared.

#### Seeing what each run bound to

Every `launch()` now records its resolved rebinds on the run row as JSON. Query it via the DuckDB connection:

```r
DBI::dbGetQuery(mr_con(),
  "SELECT run_id, variant_label, rebinds FROM _mr_runs
    WHERE step = ? ORDER BY started_at DESC",
  params = list("<inline:...>"))
#>            run_id variant_label                              rebinds
#> 1 run_2026_...        baseline  [{"name":"features","source":"variant",...
#> 2 run_2026_...        smoke_test [{"name":"features","source":"variant",...
```

The `value` field is human-readable: variant names stay as names, literal numbers stay as numbers, data frames show `"data.frame[<rows>x<cols>]"`. No join against `_mr_versions` required.

#### Mental model

A batch launch is N independent single launches run back-to-back, sharing nothing except the block of code and the `force` / `duckdb_seed` / `on_error` flags. Staleness, label propagation, helper tracking, and interactive-write warnings all behave per run exactly as they do in single-launch mode.

---

## Out of scope

- Parallel execution of batch members.
- `mr_hashes()` / `mr_runs()` / `mr_as_ofs()` convenience constructors (ship on demand).
- A `launch_batch()` sibling function.
- NSE in `mr_variants()` (bare-symbol variant names).
- Automatic label derivation from sweep values.
- Any change to the single-envelope `rebind` contract.

## Open questions (none blocking)

- **Summary print format.** `message()` emits one line per run today. A batch of 9 produces 9 headers plus 9 timing lines. Quiet mode or a rollup print may be needed but can wait for first practicum use.
- **`.labels` interaction with `variants()` / `variants_unexplored()`.** Explicit labels in a sweep show up in `variants()` output as if user-typed. Expected and desired, but worth a sanity test.
