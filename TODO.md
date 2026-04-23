# modelrunnR TODO

## Surfaced 2026-04-22 (far-future stretch)

### Multi-language script support via existing bridges

v0.1 scope: R steps and SQL steps. Python is out of scope for the
package — if a project needs it, hack it together outside modelrunnR
(e.g. `system2("python", ...)` or a side reticulate call in an R step).

Far future: add first-class script kinds for other languages via
`Suggests:`-level integrations, so users don't pay the dep cost unless
they opt in:

- Python → `reticulate`
- Rust → `extendr` (`rextendr`)
- C++ → `Rcpp`
- (open) Julia → `JuliaCall`; shell → direct `system2`

Each would be a new step kind alongside R and SQL, reusing the same
harness (code_hash of the script source, rebind semantics, staleness
check, `_mr_runs` row). Defer until R + SQL are stable and someone has
a concrete use case.

### Map out phases / versioning roadmap

No explicit phase plan exists. Write one: what lands in v0.1 (current
R + SQL + batch launches + append-mode stow), v0.2, and further out
(e.g. multi-language above, remote executors, richer diagnostics).
Lets "is this in scope?" triage be a lookup instead of a judgment
call. Target: a short `docs/roadmap.md` keyed to DESCRIPTION version
bumps.

## Surfaced 2026-04-21 (design question — append-mode stow)

### Tabular `stow()` becomes append-by-default; runs are first-class

Today `stow(df, "metrics")` creates a new **version** per call — each
run's metrics sit in their own `metrics__<hash>` physical table, and
`grab("metrics")` returns only the latest. Running 20 models produces
20 disjoint one-row versions instead of one 20-row table.

**Decisions (2026-04-21 conversation):**

- **Contract flips for data frames / tables.** Tabular stow appends to
  a single growing physical table by default. Versioned stow remains
  the default for non-tabular (artifact) objects — no change there.
- **Runs are a first-class query dimension.** Each appended row is
  stamped with `run_id` (and probably `variant_label`). `grab("metrics")`
  defaults to *latest run's rows only*; full history is an explicit
  knob.
- **Breakage assessment.** Accepted as non-breaking from a user's
  perspective — the observable behavior of `stow(df, name)` followed
  by `grab(name)` round-trips the data they just wrote, same as
  before. Residue: orphaned versioned `metrics__<hash>` tables for
  users with existing DuckDB stores. Fine to leave; `prune_versions()`
  already handles cleanup.

**Still to sort in the spec (write under
`docs/superpowers/specs/2026-04-22-append-mode-stow-design.md`):**

- Hash contract / staleness for a growing table. Likely: hash the
  appended chunk, not the whole table.
- Schema drift across runs (column added/removed between models) —
  probably `bind_rows`-style with `fill = TRUE`.
- Upsert vs. pure append on re-runs of the same `run_id` (skipped_fresh
  path shouldn't double-append; failed re-runs probably replace the
  failed run's rows).
- Composition with `rebind`, `mr_variants()`, and `prune_versions()`.
- `grab()` knob name for "give me everything, not just latest run" —
  candidates: `run = "all"`, `latest_run = FALSE`, a dedicated
  `grab_history()`.
- Invariant 4 check: migration for in-the-wild DuckDB stores that
  have versioned tabular `_mr_versions` rows. Adding an `append_table`
  kind next to `table` / `artifact` / `view` is additive and fine; no
  rename/drop of existing columns.

Target: finish 2026-04-22 — spec first, then implement.

## Surfaced 2026-04-19 (from batch-launches audit, fix-or-queue triage)

### `batch_active` flag is a side-channel; consider explicit `on_error_arg`

`R/launch_one.R` and `R/launch_sql.R` both gate their re-raise via
`isTRUE(.mr_state$batch_active)`. That flag is set/restored on the
`.mr_launch_batch*` stack frame. Reasonable today, but any future
caller of `.mr_launch_one`/`.mr_launch_sql` must remember the
contract. Cleaner: make per-envelope behavior explicit via an
`on_error = c("raise", "capture")` argument with default `"raise"`,
and have the batch dispatcher pass `"capture"`. Removes the
`on.exit` save/restore dance and makes the contract local to the
function signature.

### `mr_envelopes()` doesn't warn on duplicate `.label` across envelopes

Two envelopes labeled `"baseline"` both run and both stamp the same
label, breaking the "label is a tracked variant thread" invariant
that relaunch relies on. Likely a `warning()` (not an error: there
are valid reasons to deliberately repeat a label, e.g. seeded reruns).

### `do.call(rbind, rows)` is brittle if row schema diverges

Today every `_mr_runs` row goes through `.mr_write_run_row` so
schemas match. A future addition of a per-launch-only column (or a
batch that mixes R-mode and SQL-mode rows, which the current
dispatcher doesn't allow but isn't structurally prevented) would
break `rbind`. Consider `dplyr::bind_rows()` with `fill = TRUE`
semantics, or assert schema equality before rbind.

### Atomic-vector `mr_binds()` slot loses names

`as.list(c(low=0.1, mid=0.5))` strips the names. A user passing a
named atomic vector expects the names to flow into provenance;
they don't. Either preserve names explicitly when coercing
atomics, or document in `mr_binds()` that named atomic slots are
not supported (use `mr_envelopes()` for that).

### Vignette: `mr_variants()` shown via eval=FALSE; readers can't see flow

`vignettes/batch-launches.Rmd` introduces `mr_variants()` as
`eval = FALSE` because building real labeled variants upstream
adds setup overhead. Worth investing in a 5-line setup so the
`mr_variants()` flow runs end-to-end in the vignette.

### Spec ↔ vignette drift

`docs/superpowers/specs/2026-04-19-batch-launch-design.md`
section "## Vignette (feature guide)" duplicates the shipped
vignette nearly verbatim. Drift over time is likely. Consider
replacing the spec section with a one-line pointer at
`vignettes/batch-launches.Rmd`.

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
