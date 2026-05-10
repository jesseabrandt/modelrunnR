# Launch SQL as a first-class step kind

**Status:** design, approved 2026-04-18
**Scope:** `launch()`, new `mr_sql()` marker, new `kind = "view"`, `_mr_versions` + namespace guard, one vignette edit.
**Depends on:** [2026-04-17-lazy-grab-design.md](2026-04-17-lazy-grab-design.md) (must land first — this spec reuses its `source_sql` column and its shape-based `grab()` dispatch).

## Motivation

The north star workflow is "feature-engineer, then model". Today the feature-engineering half has to happen in R — even when the work is pure SQL (window functions, joins, lag/lead, aggregates) that DuckDB executes natively. Routing that work through R costs a `collect()` hop for no gain, and hides the SQL behind `dbplyr` verbs that don't always express what the user wants.

The first real consumer is the **AI-industry-dynamics practicum**: panel-data feature sets that are natural to write as window SQL over large ingested tables. The practicum needs SQL steps to be tracked, hashable, labelable, and rebindable — in other words, first-class, not a second-class helper inside an R `launch()` block.

**Core insight:** Since DuckDB views are essentially free (DDL, no rows computed, no storage), a "SQL step" can default to materializing *a view definition*, not a table. A pipeline step for a view is only cheap if the step itself is cheap; anything else reintroduces the overhead the design was meant to avoid. Table materialization is an explicit opt-in for expensive feature work.

## Target vignette snippet (what success looks like)

```r
library(modelrunnR)

# Earlier: panel_raw was ingested server-side from a CSV.

launch("features.sql")           # SQL step: registers a view, no rows computed

launch({                         # R step: lazy grab, collect for lm()
  fit <- lm(y ~ lag_sales + x, data = grab("features") |> dplyr::collect())
  stow(fit, "fit_v1")
}, label = "baseline")
```

…where `features.sql` is a **bare SELECT with a declarative header**:

```sql
-- @inputs: panel_raw
SELECT firm_id, year,
       lag(sales) OVER (PARTITION BY firm_id ORDER BY year) AS lag_sales
FROM panel_raw;
```

Inline equivalent (same semantics, no file on disk):

```r
launch(mr_sql("
  -- @inputs: panel_raw
  -- @output: features
  SELECT firm_id, year,
         lag(sales) OVER (PARTITION BY firm_id ORDER BY year) AS lag_sales
  FROM panel_raw;
"))
```

## Rules

### 1. Dispatch

`launch()` gains two new first-argument forms, resolved *before* any existing dispatch:

- **File mode (SQL):** first argument is a character path ending in `.sql` (case-insensitive). Routes to the SQL launcher.
- **Inline mode (SQL):** first argument is a call to `mr_sql("…")`. Dispatch is by class, parallel to how inline R is detected via `is.call() && identical(expr[[1]], as.name("{"))`.

Everything else (`.R` paths, `{ … }` blocks, `mr_label()`) keeps its current behavior. One `launch()` entry point — no `launch_sql()` alias. The marker is named `mr_sql()` (not `sql()`) to avoid colliding with `dbplyr::sql()`, matching the existing `mr_label()` / `mr_hash()` / `mr_run()` / `mr_variant()` family.

### 2. File / inline contents: bare SELECT

The `.sql` file (or the string inside `mr_sql()`) contains:

1. Zero or more header comment lines at the top (see §3).
2. A **bare query body** — exactly one statement. Either a plain `SELECT` or a `WITH … SELECT` (CTEs are first-class; they're the natural way to write multi-step feature engineering as a single logical step).

modelrunnR owns the wrapping. It is a `launch()`-level decision whether to wrap as `CREATE OR REPLACE VIEW <output> AS <body>` (default) or `CREATE OR REPLACE TABLE <output> AS <body>` (see §5). The user's file contains only the query body.

**Errors at parse time** (before any DB write):

- Body's first non-comment keyword is `CREATE`, `INSERT`, `UPDATE`, `DELETE`, `ALTER`, `DROP`, or anything other than `SELECT` / `WITH` → `"launch(): .sql must contain a bare SELECT (or WITH … SELECT); modelrunnR owns the CREATE wrapper. Strip the CREATE/INSERT/etc. and leave just the query body."`
- A `WITH` that resolves to a terminal statement other than `SELECT` (e.g. `WITH cte AS (...) INSERT INTO …`) → same error as above.
- More than one statement (multiple `;` separating non-trailing content) → `"launch(): .sql must contain exactly one statement; multi-statement SQL is not supported in this spec."`
- A trailing `;` is allowed and stripped before wrapping.

Detection is lexical: strip leading `--`-prefixed lines and whitespace, match the first keyword against `SELECT` or `WITH` (case-insensitive). For `WITH`, scan forward past balanced parens to the terminal keyword and require `SELECT`. Good enough for the first release; a DuckDB-based validation pass can come later if it proves necessary.

### 3. Declarative header

Header lines appear at the top of the file/string, before the SELECT, each starting with `--` followed by `@key:`. Recognized keys:

- `-- @inputs: <name>[, <name>…]` — required if the SELECT references any modelrunnR-managed logical name. Comma-separated, single line. Repeating `@inputs` across lines is not supported in this spec (keeps parsing trivial).
- `-- @output: <name>` — optional for file mode (defaults to filename stem without the `.sql`); **required** for inline mode (no filename to derive from).

Unknown `@key:` headers error: `"launch(): unrecognized SQL header '@<key>'. Supported: @inputs, @output."`

Malformed lines (e.g. `-- @inputs` with no colon, `-- @output: a, b` with multiple names) error with a specific message per case.

Non-`@` comments (`-- just a note`) are ignored.

Header syntax follows the convention established by sqlc / yesql for annotating SQL files with tool-level metadata. It is not dbt-style (`{{ ref('name') }}`), which would require a templating engine and is explicitly out of scope.

### 4. View semantics and content hashing

A new kind is added to `_mr_versions.kind`: **`"view"`**.

- Physical name: same scheme as existing kinds — `<logical>__<short_hash>`. Stored as a DuckDB view (`CREATE OR REPLACE VIEW <physical> AS <rendered_sql>`) rather than a table.
- `content_hash`: hash of the **rendered SQL** (the string that gets handed to DuckDB's `CREATE OR REPLACE VIEW`). Since a view has no materialized rows, the SQL text *is* the identity. Two views with identical rendered SQL are the same version; a different `@inputs` rebind produces different rendered SQL and therefore a different hash.
- `source_sql`: populated with the rendered SQL (reuse of the lazy-grab column — same machinery, different semantic role: informational for `kind = "table"`, identity-bearing for `kind = "view"`).
- `storage_location`: `NULL` (like tables — views don't live on disk as separate files).

Rendered SQL = the user's SELECT body with any rebind substitutions applied (see §6), wrapped in `CREATE OR REPLACE VIEW <physical> AS …`. It is what gets hashed, not the user's raw file bytes (those go in `code_body`).

### 5. Materialization opt-in (TABLE mode)

`launch()` gains one new argument:

- `materialize` (logical, default `FALSE`). When `TRUE`, the SQL step is wrapped as `CREATE OR REPLACE TABLE <physical> AS <body>` instead of a view. The resulting `_mr_versions` row has `kind = "table"`, `content_hash` computed from the materialized rows (reusing `.mr_hash_duckdb_table` from the lazy-grab spec), and `source_sql` populated informationally (same as stow-of-lazy-tbl today).

Applies only when the first argument is a `.sql` file or `mr_sql()` marker; otherwise ignored. (Passing `materialize = TRUE` to an R-mode `launch()` is a no-op, not an error — keeps the signature clean.)

Expensive feature work that will be consumed many times downstream is the intended use case. Default remains view because cheap-to-register is the whole reason a SQL step makes sense as a pipeline unit at all.

### 6. Input resolution and rebind

At launch time, before executing anything:

1. Parse `@inputs` to a character vector.
2. Resolve each to a `_mr_versions` row via the normal latest-version lookup (or via `rebind =` if the caller supplied a reference for that name).
3. For each input name, verify a DuckDB relation with that logical name actually exists (the `.mr_refresh_latest_view` machinery already provides this for `kind = "table"` stows; lazy-grab extends it to lazy stows; this spec adds it for `kind = "view"`). If missing, error with `"launch(): @inputs references '<name>' but no stowed value exists. Did you stow() or ingest() it first?"`
4. Apply rebind substitutions textually to the SELECT body. Substitution rule: for each `(name, reference)` pair where `name` appears in `@inputs`, rewrite occurrences of `name` as a bare identifier in the body to the physical name of the rebound version. Rewriting uses a word-boundary regex — `\bname\b` — so occurrences inside string literals and column aliases are *not* substituted. Case-sensitive.

   This is deliberately simple: no SQL AST. It covers the intended use (rebinding a modelrunnR-managed logical name to a specific historical version) and leaves anything fancier to follow-ups.
5. Record each resolved input as an `(name, content_hash)` pair on the run row's `inputs` column — same shape as R-mode runs.

FROM-clause introspection as a cross-check ("does `@inputs` match what the SQL actually references?") is a post-spec follow-up. It would catch stale headers but isn't load-bearing for correctness, and DuckDB doesn't expose a lightweight parse-to-tables API we'd want to adopt today.

### 7. `grab()` return is unchanged from lazy-grab

Per lazy-grab §1, `grab()` dispatches on shape, not storage kind:

- `kind = "table"` → lazy `tbl_dbi` (lazy-grab's path).
- `kind = "view"` → lazy `tbl_dbi`. Internally this is `dplyr::tbl(con, physical_name)`; DuckDB inlines the view definition at query-plan time and the consumer cannot tell the difference from a materialized table. `collect()`, chained verbs, `show_query()`, and auto-collecting consumers (`lm`, `ggplot`) all behave identically.
- `kind = "artifact"` → materialized R object.

No new branches in `grab()` are needed beyond adding `"view"` to the set of kinds that route to the tabular path. See §9 for the namespace guard.

### 8. Run row and step identifier

SQL runs write to `_mr_runs` with the exact same schema as R runs. Differences in how columns are populated:

- `step`:
  - File mode: `normalizePath(sql_path, mustWork = TRUE)` — same as R file mode.
  - Inline mode: `sprintf("<inline:sql:%s>", substr(expr_hash, 1, 12))`. The `sql` infix distinguishes inline SQL from inline R (`<inline:<hash>>`) so the two namespaces don't collide on hash prefix alone.
- `code_body`:
  - File mode: raw file bytes (same as R).
  - Inline mode: the string passed to `mr_sql()`.
- `code_hash`: hash of `code_body`. SQL has no transitively-sourced helpers, so the helpers input to `.mr_code_hash*` is always the empty list.
- `helpers`: `[]`.
- `inputs`: resolved `@inputs` as `(name, content_hash)` pairs.
- `outputs`: one pair — `(output_name, content_hash_of_new_version)`.
- `external_inputs`: honored, same semantics as R mode (`launch("f.sql", external_inputs = list(files = "..."))` still works).
- `duckdb_seed`: honored from lazy-grab spec §5 — applied before executing the `CREATE OR REPLACE VIEW`/`TABLE`. Rarely meaningful for views (the view definition doesn't run sampling until someone `collect()`s it), but meaningful for `materialize = TRUE` steps that use `random()` / `setseed`.
- `variant_label`: honored, same propagation rules as R mode.
- `status`: `"success"` / `"error"` / `"skipped_fresh"` — same three values.

### 9. Namespace guard extension

`.mr_guard_namespace` currently errors on cross-kind name collision (table vs artifact). Extend to include view:

- `view` vs `table`: error. (A name previously stowed as a materialized table can't be relaunched as a view without explicit replacement.)
- `view` vs `artifact`: error.
- `view` vs `view`: allowed. New version if `source_sql` differs; no-op update to `last_seen` if identical.

Error message template stays the same: `"launch(): '<name>' already exists as a <kind>; …"`.

**Note on user experience:** if someone runs `launch("features.sql")` (view) after a prior `stow(df, "features")` (table), they get a clear error pointing them at `prune_versions("features")` or renaming. No silent reinterpretation.

### 10. Relaunch, label, skip-on-fresh, force

All honored identically to R mode.

- `launch(mr_label("baseline"))` resolving to a SQL step: re-sources the file if present, else evaluates the `code_body` snapshot — exactly the current file/inline fallback. Label auto-inherits unless overridden.
- `skip_if_fresh`: `.mr_is_stale` sees a SQL step as fresh when (a) `code_hash` matches the last run under this label, (b) `@inputs` resolve to the same `(name, content_hash)` set, and (c) declared `external_inputs` hash identically. Same three ingredients as R mode.
- `force = TRUE`: re-runs regardless.
- Nested launches: still forbidden, same error.

Since SQL has no helper files, the "helper hash changed → stale" condition from R mode is vacuous — helpers is always `[]`.

## Out of scope (explicit non-goals)

- **Multi-statement SQL files.** One SELECT per step. A file with setup/teardown DDL is outside the model; keep SQL steps purely declarative.
- **SQL-from-SQL sourcing.** No `source()`-equivalent for `.sql` files referencing other `.sql` files. If this becomes useful, it gets its own spec.
- **FROM-clause introspection.** Declarative `@inputs` is the single source of truth in this spec; introspection-as-cross-check is a follow-up.
- **Jinja / dbt-style templating.** No `{{ ref('x') }}`, no macros, no conditionals. If that world is wanted, reach for dbt.
- **Non-DuckDB backends.** Everything assumes the modelrunnR-owned DuckDB connection. Foreign `DBI` connections are not accepted.
- **`@output: <name>` as an alias mechanism** (multiple outputs, one per CTE, etc.). One step, one output.
- **Auto-propagation into existing stow/grab of `kind = "view"` directly from user code.** Users don't `stow(<view_name>, …)` by hand; views come only from `launch()` on SQL. Preserves the invariant that `kind` is determined by the producer pathway, not by a runtime branch in `stow()`.

## Breaking changes

None. This is a pure addition. Existing R `launch()` calls are unaffected; the `materialize` argument defaults to `FALSE` and is ignored outside SQL mode; `mr_sql()` is a new export; `kind = "view"` is a new enum value with no backward-incompatible reinterpretation of existing rows.

## Tests to add (`tests/testthat/`)

`test-launch-sql-file.R`:
- `launch("features.sql")` with a valid bare-SELECT file and `@inputs: panel_raw`: returns a run row, creates `_mr_versions` row with `kind = "view"`, `source_sql` populated, `content_hash` deterministic.
- `grab("features")` after the launch returns a lazy `tbl_dbi` that `collect()`s to the expected rows.
- Re-running the identical file under the same label skips as fresh (`status = "skipped_fresh"`).
- Editing the SELECT body produces a new version (new `content_hash`) and re-runs.
- `@output: <name>` header overrides the filename-stem default.
- Omitted `@inputs` when the SELECT references a modelrunnR-managed name: errors up-front.
- File with `CREATE TABLE … AS SELECT …` errors with the "bare SELECT" message.
- File with two `SELECT` statements errors with the "one statement" message.
- Unknown `@foo:` header errors.
- Missing file: errors with path (reuses the existing R-mode error).

`test-launch-sql-inline.R`:
- `launch(mr_sql("-- @inputs: panel_raw\n-- @output: features\nSELECT * FROM panel_raw"))` works; step is `<inline:sql:<hash>>`; `code_body` is the string.
- `mr_sql()` without `@output:` errors with "inline SQL requires @output:".
- `mr_sql()` object passed anywhere other than `launch()`'s first arg behaves as a plain object (not callable); no leaky side effects.

`test-launch-sql-materialize.R`:
- `launch("features.sql", materialize = TRUE)` produces `kind = "table"`, hashes table rows (reuses lazy-grab's `.mr_hash_duckdb_table`), and `grab("features")` returns a lazy tbl that `collect()`s identically to the view version (same rows, same types).
- Switching a step from view to table (or vice versa) under the same name requires a `prune_versions` call or a different name; verify the namespace-guard error.

`test-launch-sql-rebind.R`:
- `launch("features.sql", rebind = list(panel_raw = mr_hash(<older_hash>)))` rewrites the SELECT body to reference the rebound physical name, produces a different `content_hash` than the default, and the view definition points at the older table.
- Rebind referencing a name not in `@inputs`: errors `"rebind: 'foo' not declared in @inputs"`.
- Rebind's word-boundary substitution: the identifier is rewritten in `FROM panel_raw` but not inside `AS 'panel_raw_note'` (string literal) or `AS panel_raw_delta` (suffixed identifier).

`test-launch-sql-errors.R`:
- Each of the enumerated parse-time error cases fires before any DuckDB write occurs (assert `_mr_runs` / `_mr_versions` row count unchanged after the error).
- Cross-kind namespace collision: prior `stow(df, "features")` then `launch("features.sql")` errors with the expected message.

## Vignette edits

### Edit: `vignettes/getting-started.Rmd`

Add one section after the existing stow/grab intro, titled "SQL steps": demonstrate `launch("features.sql")` producing a view, then an R `launch()` that consumes it via `grab() |> collect()`. Three code blocks, ~12 lines total. Anchor the practicum-flavored example so the vignette tells a single end-to-end story.

### New: `vignettes/sql-steps.Rmd` (optional, decided at implementation time)

Deeper dive if the getting-started addition feels cramped. Sections: (1) file vs. inline, (2) view vs. materialize, (3) rebind and labels, (4) when to reach for SQL vs. dplyr. Not a blocker for merge.

## Documentation updates

- `launch()` man page: new `@section` on SQL mode; document `materialize`; add an example.
- `mr_sql()` man page (new, exported): purpose, header syntax, one-line example.
- `NEWS.md`: "SQL launches are first class: `launch('features.sql')` registers a DuckDB view tracked identically to R runs. Opt into table materialization with `materialize = TRUE`. See `vignette('getting-started')`."
- `grab()` man page: add a sentence noting that `kind = "view"` values route to the same lazy-tbl path as `kind = "table"` (consumer doesn't care).

## Implementation notes (non-normative; inform the plan)

- **Parsing:** a small pure helper `.mr_parse_sql_header(text)` that returns `list(inputs = chr, output = chr_or_null, body = chr)` and throws on malformed headers or non-SELECT bodies. Unit-test it in isolation; the rest of the SQL path calls it.
- **Dispatch:** extend `launch()`'s existing dispatch ladder. Check `.sql` extension / `mr_sql` class first; fall through to current R-mode logic otherwise. One new branch in `launch()` proper; the heavy lifting lives in `.mr_launch_sql(file_or_body, inline, materialize, rebind, label, external_inputs, force)`.
- **Execution:** one DuckDB statement per step — the rendered `CREATE OR REPLACE VIEW` (or `TABLE`). No transaction needed for view mode (single DDL); table mode reuses the existing table-stow transaction wrapper.
- **Hashing:** view-mode `content_hash = .mr_hash_bytes(charToRaw(rendered_sql))`. Table mode reuses `.mr_hash_duckdb_table` per lazy-grab.
- **`_mr_refresh_latest_view`** keeps its current name but gets one new case: when the latest version of a logical name has `kind = "view"`, the "latest" view at `<logical>` is `CREATE OR REPLACE VIEW <logical> AS SELECT * FROM <physical>` — a one-level indirection through the versioned physical view. Same shape as today; only the downstream physical object changes.
- **`mr_sql()` export:** a tiny constructor returning a classed list (`list(kind = "sql", body = x)` with class `c("mr_ref_sql", "mr_ref")`), detected in `launch()` via `inherits(script_path, "mr_ref_sql")`. Symmetric with `mr_label()` / `mr_hash()` / etc.
- **Schema migration:** `_mr_versions.kind` is `TEXT` already, no schema change needed for the new enum value. `source_sql` is added by the lazy-grab migration; this spec piggybacks.

## Follow-ups (not in this spec)

- FROM-clause introspection as a cross-check against `@inputs`.
- Multi-statement SQL files and SQL-from-SQL sourcing.
- `mr_sql()` accepting a `file = "path.sql"` argument as a third dispatch form, for callers who want the inline API but file-backed content.
- View-to-table promotion: a `promote_to_table("features")` that materializes a view's current definition under a new `kind = "table"` version, for cases where a view's cost becomes high in practice.
- Cross-launch SQL helpers (`source("helpers.sql")`-equivalent), if a real use case surfaces.
