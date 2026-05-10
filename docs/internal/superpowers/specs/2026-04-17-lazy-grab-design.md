# Lazy `grab()` and server-side `stow()`

**Status:** design, approved 2026-04-17
**Scope:** `grab()`, `stow()`, `ingest()`, `launch()`, and two vignettes.

## Motivation

The north star says a user should be able to "replace `read_csv()` with `grab()`" — but the core motivating workflow includes CSV files that don't always fit in memory. Today `grab()` materializes everything into R, which breaks that promise exactly when it matters most.

The first real consumer is the **AI-industry-dynamics practicum**: large time-series CSVs that need to stay on disk / in DuckDB, with R touching only samples or aggregates. This spec makes `modelrunnR` honor lazy, DuckDB-backed reads end-to-end, and lets whole pipeline steps stay server-side when the user wants that.

## Target vignette snippet (what success looks like)

```r
library(modelrunnR)

launch({
  # Lazy reference to the CSV; nothing pulled into R yet.
  raw <- grab("sales_2024", source = "data/sales_2024.csv")

  # Sample in DuckDB, then materialize.
  sample <- raw |>
    dplyr::slice_sample(n = 1000) |>
    dplyr::collect()

  fit <- lm(price ~ sqft + beds, data = sample)
  stow(fit, "fit_baseline")
}, label = "baseline", duckdb_seed = 0.42)

# Whole step stays server-side — zero R-side materialization:
launch({
  grab("sales_2024") |>
    dplyr::filter(year == 2024) |>
    dplyr::group_by(region) |>
    dplyr::summarise(total = sum(price)) |>
    stow("sales_by_region_2024")
}, label = "regional_rollup")
```

## Rules

### 1. `grab()` return type is shape-based, not storage-based

- **Tabular** stored value (ingested CSV, stowed data.frame/tibble) → `dbplyr` lazy `tbl_dbi`.
- **Non-tabular** stored value (model, list, vector, function, anything artifact-serialized) → materialized R object, unchanged from today.

The rule is about *shape*, not storage kind. An `.rds` file containing a data.frame would be lazy; an `.rds` containing a model would be materialized. (RDS ingest is not in scope for this spec — just documenting that the rule generalizes.)

No subclass, no custom class. `grab()` returns a plain `tbl_dbi` for tables; users get normal `dbplyr` semantics. Consequences:

- `dplyr` verbs compose lazily.
- `dplyr::collect()`, `as.data.frame()`, `tibble::as_tibble()` all materialize.
- `lm()`, `glm()`, `ggplot()`, and most `stats::*` auto-collect silently via `as.data.frame.tbl_sql` (inherited from `dbplyr`). No warning message — we intentionally do not subclass to add one, because `dplyr` verbs strip custom subclasses and the message would fire inconsistently.
- `$col` and base `x[rows, cols]` do **not** work on lazy tbls — users see the standard `dbplyr` error. Workaround is `dplyr::pull(col)` or an explicit `collect()`.

### 2. `stow()` accepts a lazy `tbl`

New dispatch branch at the top of `stow()`:

```r
if (inherits(value, "tbl_lazy")) {
  .mr_stow_lazy(name, value)        # server-side CREATE TABLE AS
} else if (is.data.frame(value)) {
  .mr_stow_table(name, value)       # existing path
} else {
  .mr_stow_artifact(name, value)    # existing path
}
```

Server-side path (`.mr_stow_lazy`):

1. Verify the lazy tbl is bound to modelrunnR's own DuckDB connection (`dbplyr::remote_con(value)` identity check). If not, error: `"stow(): lazy tbl is bound to a different DBI connection; call collect() first and stow the result."`
2. Render SQL: `sql <- dbplyr::sql_render(value)`.
3. Create a temp table via `CREATE TABLE <temp> AS <sql>`, hash it, register in `_mr_versions` through the existing table-stow machinery.
4. Store the rendered SQL on the new `_mr_versions.source_sql` column.
5. Same namespace guard as materialized stows (`.mr_guard_namespace(name, "table")`).
6. Record the write on the run row as an output pair, same as today.

### 3. `ingest()` becomes server-side

**Breaking:** `ingest()` currently reads the whole CSV into an R `data.frame` via `.mr_read_file()` and then calls `.mr_stow_table()`. This defeats the lazy promise on the first `grab(source = path)` — a 10GB CSV blows through R memory before `grab()` ever returns anything.

Refactor:

- Replace `.mr_read_file()` → `.mr_stow_table()` with a server-side path:
  ```sql
  CREATE TABLE <physical_name> AS
  SELECT * FROM read_csv_auto(?, HEADER=TRUE);
  ```
  (Parameter for the path; DuckDB's `read_csv_auto` handles inference.)
- Hash the resulting DuckDB table directly. The existing table-hash path in `.mr_stow_table` already operates over a DuckDB table, so factor it out into `.mr_hash_duckdb_table(physical_name)` and reuse.
- `source_uri` + `source_hash` recording on `_mr_versions` is unchanged.
- Return value becomes an invisibly-returned lazy `tbl_dbi` (was: invisibly the materialized frame). Keeps symmetry with `grab()`.
- Parquet path: `read_parquet(path)` — already server-side capable; just route through the same pattern.

Internal callers (`.mr_maybe_ingest`) are unaffected — they don't use the return value.

### 4. Version-selector consistency

All `grab()` selectors follow the same tabular-vs-non-tabular rule:

- `grab(name)` — latest.
- `grab(name, version = hash)`.
- `grab(name, from_run = run_id)`.
- `grab(name, as_of = timestamp)`.
- `grab(name, variant = label)`.
- `launch(rebind = list(name = mr_hash(hash)))` — same rule inside the block.

If the resolved `_mr_versions` row is `kind = "table"` → lazy tbl. If `kind = "artifact"` → materialized object.

### 5. `launch()` gets `duckdb_seed`

New argument: `duckdb_seed` (numeric, default `NULL`).

- When non-null, `launch()` calls `DBI::dbExecute(con, "SELECT setseed(?)", params = list(duckdb_seed))` after opening the connection and before evaluating the block.
- **Range validation:** must satisfy `-1 <= duckdb_seed <= 1` (DuckDB's documented range). Otherwise error: `"launch(): duckdb_seed must be in [-1, 1]; got <value>."`
- **Persistence of value:** stored on the run row in a new nullable column `_mr_runs.duckdb_seed` (DOUBLE). Kept in the `code_body` too (since it's a `launch()` arg, it's in the call — but the explicit column makes it queryable without parsing).
- **RNG state after the block:** not restored. DuckDB's RNG is a connection-level stream; `setseed` only exposes a setter, not a save/restore API. Documented limitation: "if you use lazy sampling outside `launch()` after a `duckdb_seed`-ed run, the RNG state is wherever the block left it."

### 6. `mr_con()` exported

Trivial wrapper around `.mr_get_connection()`. Rationale: users who want sampling schemes `dbplyr` doesn't express (bootstrap, stratified, custom) need to drop to raw SQL. Without `mr_con()` they can't get the connection without touching internals.

```r
#' Return the DuckDB connection modelrunnR is using
#' @export
mr_con <- function() .mr_get_connection()
```

### 7. Input / output recording — unchanged semantics

- `inputs` on the run row: named stored values read, at their content_hash. `grab()` records at call time, based on the version resolved. Lazy vs. materialized return doesn't affect what's recorded.
- `outputs` on the run row: named stored values written, at their content_hash. `stow()` of a lazy tbl records the hash of the resulting DuckDB table (computed post-`CREATE TABLE AS`).
- **New column `_mr_versions.source_sql`** (nullable TEXT): populated only when an output was produced via `stow(<lazy_tbl>, ...)`. Purely informational — not used in staleness, not part of content_hash.

### 8. `skipped_fresh` path — unaffected

When a `launch()` is skipped because the step is fresh, no block runs, no `grab`/`stow` fires, no lazy tbls created. The `skipped_fresh` row is written as today. No changes needed, just noting for completeness.

## Out of scope (explicit non-goals)

- Custom sampling schemes inside `modelrunnR` (bootstrap, stratified, grouped CV). Users do these in R or via `mr_con()` + raw SQL; the "index in R, stow fold tables, grab per fold" pattern is just normal `grab`/`stow` usage and needs no new API.
- Lazy-via-R-promises for non-tabular artifacts. Cosmetic win at best; RDS/qs2 is opaque bytes until fully deserialized, so "defer the read" trades an early error for a later confusing one.
- Auto-linking R's `set.seed()` to DuckDB's RNG. The two are independent streams; pretending otherwise is a leaky abstraction.
- `.rds` source support on `grab(source = path)`. The rule-would-generalize note in §1 is aspirational; implementing it is its own spec.
- A warning message on auto-collect (the earlier "option 3" — walked back because `dplyr` verbs strip custom subclasses and the message would fire inconsistently).

## Breaking changes

1. **`grab()` on any stored table now returns a `tbl_dbi`**, not a `data.frame`. Existing callers that branch on `is.data.frame()`, use `$col`, or do base `[` subsetting will break. Auto-coercion via `as.data.frame` / `model.frame` catches most consumers silently, but not all.

   *Migration:* pipe through `dplyr::collect()` where a materialized frame is needed.

2. **`ingest()` return type changes** from invisible `data.frame` to invisible lazy `tbl_dbi`. Most callers ignore the return; any that used it as a frame will need `|> collect()`.

3. **`stow()` on a lazy tbl no longer errors.** It used to fall through to the artifact path and fail in `qs2` serialization. Non-breaking in the sense that no correct code depended on the old failure.

Mention all three in `NEWS.md`.

## Tests to add (`tests/testthat/`)

`test-grab-lazy.R`:
- `grab(name, source = path)` on a first-time ingest returns `tbl_dbi`.
- `grab(name)` on an already-ingested table returns `tbl_dbi`.
- `grab(name, source = path)` when file hash changed re-ingests and returns `tbl_dbi` over the new version.
- `grab(name)` on a stowed model (non-tabular) still returns the model.
- `grab(name)` with each selector (`version`, `from_run`, `as_of`, `variant`, via `launch(rebind=)`) obeys the shape rule.
- `as.data.frame(grab("x"))` materializes; `dplyr::collect(grab("x"))` materializes; `tibble::as_tibble(grab("x"))` materializes.
- `grab("x") |> dplyr::slice_sample(n = 5) |> dplyr::collect()` returns 5 rows and doesn't pull the full table (measurable via DuckDB's `EXPLAIN` or just row count on a large fixture).

`test-stow-lazy.R`:
- `grab("x") |> dplyr::filter(...) |> stow("y")` creates the DuckDB table for "y", populates `_mr_versions.source_sql`, and `grab("y")` round-trips.
- `stow()` on a lazy tbl bound to a foreign `DBI` connection errors with the expected message.
- Server-side stow records an output pair on the run row with the correct content_hash.
- `source_sql` is NULL on materialized-frame stows and artifact stows.

`test-ingest-serverside.R`:
- `ingest("big", "big.csv")` on a large fixture does not load the file into R (assert R-side memory doesn't spike — or at least that R never binds the frame; easier: assert `.mr_read_file` is not called).
- Content hash of the resulting table is stable across repeated ingests of the same file.
- `source_uri` + `source_hash` are recorded on the new `_mr_versions` row.

`test-launch-duckdb-seed.R`:
- `launch({... slice_sample(n = N) |> stow(...) ...}, duckdb_seed = 0.42)` run twice with the same seed produces identical output hashes.
- Different seeds produce different hashes.
- `duckdb_seed = 2` errors with the range message.
- Run row records the seed value in the new column.
- Omitting `duckdb_seed` is unchanged (existing tests still pass).

`test-mr-con.R`:
- `mr_con()` returns the same connection as `.mr_get_connection()`.
- `DBI::dbGetQuery(mr_con(), "SELECT 1")` works.

## Vignettes

### New: `vignettes/lazy-data.Rmd`

Base structure (flesh out with prose):

- Section 1: "`grab()` returns a lazy reference for tables." Contrast with `read_csv()`. Show that `grab(name, source = "file.csv")` ingests the file server-side the first time and returns lazy thereafter.
- Section 2: "Composing dplyr verbs." Show `filter`, `select`, `group_by`, `summarise`, `slice_sample` all stay lazy. Show `show_query()` to reveal the SQL.
- Section 3: "Materializing." Three idioms: `dplyr::collect()`, `as.data.frame()`, `tibble::as_tibble()`. Note which non-dplyr consumers auto-collect (`lm`, `ggplot`) and which don't (`$`, base `[`).
- Section 4: "Reproducible sampling with `duckdb_seed`." The target snippet. Explain that R's `set.seed()` does not affect DuckDB's RNG; `duckdb_seed` on `launch()` is the hook.
- Section 5: "Whole-step server-side pipelines with `stow(<lazy_tbl>, ...)`." The regional-rollup snippet. Show `grab()` of the stowed result returns another lazy tbl.
- Section 6: "Escape hatches." `mr_con()` for raw SQL; collect-then-sample for R-native patterns (grouped CV, rolling windows).

### Edit: `vignettes/getting-started.Rmd`

Three touch-up spots (everything else in the vignette is unaffected):

1. `identical(training, df)` — replace with `identical(dplyr::collect(training), df)` (or drop the check; the point was that stow/grab is an identity, which is still true up to type-inference quirks).
2. Inside the `launch` block: `training <- grab("training")` → `training <- grab("training") |> dplyr::collect()`. Keeps the rest of the block working (the `$y` access and `predict()` call both expect a frame).
3. Add one sentence in the "stowing and grabbing" section noting that `grab()` returns a lazy tbl for tables, and link forward to `vignette("lazy-data")`.

## Documentation updates

- `grab()` man page: update `@return` to "A `dbplyr` lazy `tbl` for tabular values, or the materialized R object for artifacts." Add a "Materializing" paragraph listing the three idioms.
- `stow()` man page: add a "Lazy tbl values" paragraph describing the server-side path.
- `ingest()` man page: update `@return` and note "the file is read server-side via DuckDB's `read_csv_auto`; no R memory is used for the data."
- `launch()` man page: document `duckdb_seed` (including range and the no-restore note).
- `mr_con()` man page (new, exported): purpose and a one-line example.
- `NEWS.md`: bulleted breaking-change notes for the three items above.

## Implementation notes (non-normative; inform the plan)

- `.mr_hash_duckdb_table(physical_name)`: factor out of `.mr_stow_table` — takes a DuckDB table name, returns the same content hash the current machinery produces. Used by `.mr_stow_table` (materialized), `.mr_stow_lazy` (server-side), and the new `ingest()`.
- `.mr_stow_lazy(name, tbl)`: CREATE TABLE AS → hash → register `_mr_versions` row → set `source_sql` → record output pair.
- Schema migration: `_mr_versions.source_sql TEXT` and `_mr_runs.duckdb_seed DOUBLE`, both nullable. `R/schema.R` owns this; add bump + migration step.
- Connection-identity check in `.mr_stow_lazy`: `identical(dbplyr::remote_con(tbl), .mr_get_connection())`. Documented error if not.

## Follow-ups (not in this spec)

- `.rds` source support on `grab(source = path)` — shape-based dispatch (data.frame → lazy tbl via DuckDB register, else → artifact).
- Custom class with auto-collect warning message, if silent collects turn out to bite real users.
- `launch(..., duckdb_seed = ...)` integration with `force = TRUE` / relaunch semantics (re-running a seeded block under a label).
- R's `set.seed()` interop — if a natural bridge surfaces, worth reconsidering; for now, deliberately separate.
