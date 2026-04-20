# modelrunnR TODO

## Surfaced 2026-04-19 (from launch-SQL audit, fix-or-queue triage)

### `.mr_check_inputs` ignores rebind when comparing to "current latest"

`R/staleness.R` `.mr_check_inputs` compares each prior recorded input
against the current LATEST `_mr_versions` row for that name. When a
launch was made with `rebind = list(x = mr_hash(v1))`, the recorded
input is `(x, v1_hash)`. A repeated identical launch is correctly
intended to be fresh — but if `latest(x) != v1`, the staleness check
reports `input:x` and re-runs.

This applies to BOTH R-mode and SQL-mode launches; the launch-SQL
work surfaced it more sharply because rebind is so common in SQL
panel-data work. Fix likely: thread the rebind map into
`.mr_is_stale()` and prefer the rebound hash over latest when
comparing.

### `gsub` replacement string in rebind substitution isn't escaped

`R/launch_sql.R` `.mr_launch_sql` uses
`gsub(pat, .mr_quote_ident(physical_for[[nm]]), rendered_body, perl = TRUE)`.
A replacement string containing `\`, `\1`, or `$1` would be
reinterpreted by `gsub`. Currently safe (logical names are validated;
physical names are `name__hex_hash`), but a defensive
`stringi::stri_replace_all_fixed` or escape pass would future-proof.

### DRY skipped-fresh and nested-launch helpers

`.mr_record_skipped_fresh` (R/launch.R) and `.mr_record_skipped_fresh_sql`
(R/launch_sql.R) are near-duplicates. The nested-launch guard is also
duplicated between R/launch.R and R/launch.R's SQL dispatch arm.
Consolidating now would shrink the batch-launch implementation
surface; the duplication will become more painful when batch wraps
both launchers.

### Test gaps surfaced by audit

- `external_inputs = list(...)` flowing through a SQL launch is in
  scope per spec §8 but not exercised by `test-launch-sql-*`.
- Namespace guard tested only view→table direction; table→view
  reverse is also banned and untested.
- Round-trip stability of `code_hash` for a SQL launch across re-runs
  is implicit in the skip-on-fresh test but not asserted directly.

### Tighten `.mr_validate_name` allowlist

`R/validate.R` rejects path separators / `..` / control characters but
permits spaces and most punctuation. SQL launch surfaces this through
`@output: my view` (with space) producing an awkward `"my view"`
identifier downstream. A `^[A-Za-z_][A-Za-z0-9_-]*$`-style allowlist
would tighten the contract for all callers (stow, ingest, launch SQL).

### Vignette example for SQL steps could showcase window SQL

`vignettes/getting-started.Rmd`'s "SQL steps" section uses a simple
`AVG`/`COUNT` aggregate. Spec motivation is window functions / lag-lead;
a panel-flavored example would land the "this is what SQL is for"
point harder. Trade-off: pedagogy vs. brevity.

### `WITH RECURSIVE` is not handled by the SQL header parser

`.mr_with_terminal_keyword` in `R/mr_sql.R` walks the CTE list assuming
`WITH <ident> AS (...)` syntax. `WITH RECURSIVE <ident> AS (...)`
falls through and currently returns NULL, which surfaces as a
"bare SELECT" error. Not covered in v0.1 scope; spec doesn't require
it.

### Multi-statement error could quote the offending region

`R/mr_sql.R` `.mr_validate_sql_body` errors on stray `;` but the
message doesn't say where the second statement starts. A small
diagnostic improvement; low priority.

## Surfaced 2026-04-18 (from final_practicum rebind workflow)

### 1. `rebind = list(<name> = <df>)` pollutes the target's version history

Bare-value rebinds call `.mr_stow_table(name, value)` (see
`.mr_resolve_rebind_entry` in `R/rebind.R`), which writes a permanent
`_mr_versions` row under `name` and bumps `_mr_latest_view`. After a
test launch with a sampled rebind, a naked `grab(<name>)` returns the
sample instead of the real dataset.

Directions to consider:

- Scope the rebound value to the launch run only — store it under a
  launch-private physical name and resolve via `.mr_state$rebinds`
  without touching `_mr_versions` / the latest view.
- At minimum, don't refresh `latest` for rebind-originated stows.
- Alternative: reject bare values in `rebind =` and require
  `mr_hash()` / `mr_run()` / `mr_variant()` refs to pre-existing
  versions.

### 2. `stow()` of a lazy `tbl_dbi` falls through to the artifact path

`stow()` dispatches on `is.data.frame(value)`. A `tbl_dbi` / `tbl_sql` /
`tbl_lazy` is not a data frame, so it hits `.mr_stow_artifact` and gets
`qs2::qs_serialize`d as an opaque R object — the stored payload is the
query definition, not the data, and it's useless across sessions once
the connection is gone.

The existing feature-set block in `final_practicum/qmd/run_models.qmd`
(`tbl(mr_con(), dbplyr::sql(sql)) |> stow(...)`) trips this latently.

Fix: detect `tbl_dbi` / `tbl_sql` in `stow()` and materialize via
`CREATE TABLE AS` against `mr_con()` without round-tripping through R.

### 3. `stow()` signature-swap guard is too narrow

`stow()` went value-first: `stow(value, name)`. The guard only fires
when `name` is missing AND `value` is a length-one character vector.
The old `stow("ridge_preds", df)` pattern has `name` present (the data
frame), so the guard skips and the call fails later with a
less-useful error from `.mr_validate_name(<data.frame>, ...)`.

Fix: widen the guard to also detect
`is.character(value) && length(value) == 1L && is.data.frame(name)`
(and similar for artifact payloads) and point at the swap.
