# modelrunnR TODO

## Surfaced 2026-04-23 (from consolidated-branch audit)

### Shape B non-interactive provenance gap

Inside a `launch()`, `stow(df, name)` commits the data row + the
registry update in a DuckDB transaction, but the `_mr_runs.outputs`
entry (which records the `chunk_hash` for the run) is written later
by `.mr_write_run_row` outside that transaction. A process crash
between the stow commit and the run-row write leaves the rows
committed but the chunk_hash untracked in `outputs`. The data is still
queryable via `grab()` (the row's `_mr_run_id` is stamped in the
table), but `versions(name)` will omit that chunk and `mr_hash()`
rebinds against the orphaned hash can't resolve. Fix probably needs
either (a) passing `run_id` into `.mr_append_write_frame` / `_write_lazy`
and appending the output entry to `_mr_runs.outputs` inside the same
transaction, or (b) a dedicated `_mr_append_chunks` table populated
at commit time. Interacts with the chunk-entries scan performance
below — doing both at once may be cleaner.

### `.mr_append_chunk_entries` is O(n_runs) per call — full `_mr_runs` scan

Currently scans every `_mr_runs` row with a non-empty `outputs` column
and JSON-parses each one, for every Shape B grab / versions() /
mr_hash() resolution / SQL `@inputs` on a Shape B name. Acceptable
today; hits a wall once a store accumulates thousands of runs.
Cleanest fix is a dedicated `_mr_append_chunks (run_id, logical_name,
chunk_hash, rows_appended, started_at)` populated at stow commit time
and scanned by keyed query. Also resolves the "ghost chunk_hashes
after prune" issue below in the same refactor.

### Ghost chunk_hashes after `prune(name, by = "run")`

Pruning rows from a Shape B physical table doesn't remove the
`append_table` entries from `_mr_runs.outputs` JSON. `versions(name)`
afterward still lists the pruned chunk's hash; `grab(run = pruned_id)`
returns zero rows silently; `mr_hash(<pruned_hash>)` rebinds resolve
to a run whose rows no longer exist. Fix alongside the
chunk-entries lookup table above — prune both in one pass.

### DDL auto-commit around `_mr_append_tables` first-write

`CREATE TABLE IF NOT EXISTS <physical>__append` in `.mr_append_ensure_table`
runs inside the outer `dbBegin`/`dbCommit` fence in `.mr_append_write_frame`.
DuckDB auto-commits DDL in standard mode, so the CREATE TABLE is not
actually rolled back if the subsequent registry INSERT or the row
INSERT fails. Next call sees the physical table but no registry row,
ensures-table is a no-op (exists), and inserts a fresh registry row
with wrong `row_count` / `first_seen`. Needs a test against DuckDB's
actual DDL rollback behavior and, if auto-commit confirmed, a
restructure: create the physical table pre-transaction and fence only
the registry INSERT + row INSERT.

### Lazy-path vs frame-path chunk_hash semantic mismatch

`.mr_append_write_frame` hashes row contents
(`serialize(value[order(value), ], NULL)`); `.mr_append_write_lazy`
hashes the SQL body text. Two runs that produce identical rows via
different SQL get different chunk_hashes; two runs that render to the
same SQL against different upstream data get the same chunk_hash.
`versions()` surfaces these as Shape B versions but the identity
meaning isn't uniform. Pick one: either always materialize and hash
rows (temp-table + `.mr_hash_duckdb_table`), or document that lazy
chunk_hash is SQL-level and frame chunk_hash is row-level. Design
decision, not a bug — flag before v0.1.

### SQL-launch records Shape B chunk_hash on `_mr_runs.inputs`; R-launch records `NA`

`R/launch_sql.R:120-126` resolves Shape B inputs to their chunk_hash
and records it on `_mr_runs.inputs`. `R/grab.R:125` (R-launch path)
records `NA_character_` for the same Shape B grab. `.mr_check_inputs`
treats NA-hash entries as "always fresh" — so an R-mode consumer of a
Shape B input never goes stale when the upstream changes, while a
SQL-mode consumer does. Pick one convention per the
shape-invisibility principle; matching the SQL-mode behavior on R
would give real upstream-change detection for Shape B inputs.

### `serialize()`-based chunk_hash is not R-version-stable

Frame-path chunk_hash uses R's `serialize()` format, which may change
with major R upgrades. A Shape B `chunk_hash` recorded on R 4.x may
differ on R 5.x for identical content. Pre-1.0 is fine to leave; fix
pre-release by hashing a canonical representation
(`digest::digest(x, algo = "xxhash64")` on a column-wise sort) or
DuckDB-side via `.mr_hash_duckdb_table` after insert.

### Type-coerce-to-TEXT is session-TZ-dependent for POSIXct

`R/shape_append.R:122-127` — `as.character(POSIXct)` renders in the
session's TZ. Two runs in different TZs with the same instant coerce
to different TEXT values, breaking reproducibility for schema drift
involving timestamps. Fix: for POSIXct specifically, use
`format(x, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")`.

### `schema_json` column order depends on jsonlite key preservation

`fromJSON(..., simplifyVector = FALSE)` returns a named list; JSON
object key order is not guaranteed across library versions. `names(schema)`
is used to drive INSERT column order on the lazy-write path, so a
jsonlite upgrade that reorders keys could silently misalign
`INSERT ... SELECT`. Fix: align incoming columns to DuckDB physical
column order via `PRAGMA table_info(...)` rather than relying on
parsed JSON order.

### `prune(by = "run")` builds SQL `IN (...)` lists inline

`R/prune.R` uses `quote_list(ids)` to embed run ids as literals in
`IN (...)` clauses. Today's run_id format is alphanumeric (package-
generated) so no injection path, but the SQL body grows unbounded for
large prune lists. Fix: build a DuckDB temp table of ids and
`DELETE ... WHERE _mr_run_id IN (SELECT id FROM tmp)`.

### `.mr_validate_name` allowlist is permissive

`R/validate.R:29` blocks `/`, `\`, `..`, and control chars. Permits
spaces, `$`, `@`, commas, most punctuation. Combined with `gsub`
replacement in `launch_sql.R`, behavior under undefined PCRE
backreferences (`$1`, `\1`) is technically unspecified. Current R
is benign; defensive tighten to `^[A-Za-z_][A-Za-z0-9_]*$` plus
`gsub(..., fixed = TRUE)` on the substitution.

### Staging-table orphan on commit failure

`R/launch_sql.R:406` (and adjacent in `R/ingest.R`) set
`staging_alive <<- FALSE` before `DBI::dbCommit`. If commit fails,
the on.exit handler doesn't drop the staging table. Move the flag
flip to after the `dbCommit` returns. Pre-existing pattern, not new
to the append-mode branch.

### Shape A extraction to `shape_versioned.R`

Spec §12 calls for `R/shape_versioned.R` to absorb Shape A writer
logic currently sitting inline in `R/stow.R` (.mr_stow_table,
.mr_stow_artifact) and `R/versions.R`. Deferred — touches a lot of
surface and pairs naturally with the `_mr_append_chunks` refactor.

### `R/shape_append.R` (623 lines) likely wants splitting

Holds physical-name helper, type mapping, ensure-table, both write
paths (frame + lazy), reserved-cols guard, schema reconciliation,
row hash, reader, interactive-run-row writer, chunk-entry lookup,
run_id-for-hash, latest-run-id, chunk-hash-for-run, SQL view
materializer. Convention is one function per file; the shape-module
layout is an intentional exception but it's at the edge. Candidates:
`shape_append_write.R` / `shape_append_read.R` / `shape_append_meta.R`,
or update CLAUDE.md to name "shape modules" as an explicit exception.

### Helper dedup: `.mr_new_run_id` / `.mr_new_batch_id`

`R/launch.R:332-342` — six-line near-duplicates differing only in
prefix. One helper: `.mr_new_id(prefix)`.

### `_mr_runs.outputs` shape-discriminator duplicated across files

Five files (`propagation.R`, `staleness.R`, `interactive.R`,
`variants.R`, `versions.R`) each switch on `{kind, logical_name}` vs
`{name, hash}`. Centralize in a `.mr_output_matches_name(entry, name)`
helper returning TRUE for either shape.

### SQL-launch `\bname\b` substitution can chain-collide

`R/launch_sql.R:171-174` applies rebind substitutions iteratively via
word-boundary regex. If an earlier substitution produces a physical
name that matches a later logical name's word boundary, subsequent
passes can double-rewrite. Edge case; real SQL with `name__hex_hash`
physical names won't collide in practice. Consider placeholder
replacement (two-pass: name -> UUID -> physical) for defense.

### Batch vignette reads like Shape A semantics

`vignettes/batch-launches.Rmd:164-178` uses `stow(data.frame(), "src")`
producing "versions" — under the new contract this is Shape B, so the
per-call chunks are surfaced as versions via the Option Y amendment,
but the vignette narrative still describes it in Shape A terms. Fix:
either switch the vignette source to `ingest()` (keeps Shape A) or
rewrite the surrounding prose to name the chunk-per-append model.

## Surfaced 2026-04-23 (from feat/batch-id merge)

### SQL-mode batch_id coverage dropped in merge — needs Shape-B-friendly rewrite

The merge of feat/batch-id into feat/append-mode-stow dropped two SQL-batch
tests ("SQL batch fans out one envelope per version of a rebound input" and
"SQL batch with one bad rebind still records the others") because both
harvested Shape A content hashes via `stow(data.frame(), "src")` +
`mr_versions_rows("src")$content_hash`. Under the append-mode contract
`stow(data.frame())` routes to Shape B, so the helper returns zero rows.

R-mode batch_id coverage is retained in `tests/testthat/test-launch-batch.R`.
SQL-mode should get equivalent coverage via `ingest()` for the source data
(which stays Shape A) so `mr_hash()`-rebound SQL batches remain tested.

## Surfaced 2026-04-23 (from append-mode stow plan)

### `.mr_stow_lazy` is dead code after Task 9

The Shape A lazy-tbl writer (`R/stow_lazy.R :: .mr_stow_lazy`) has zero
callers after Task 9 flipped `stow(tbl_lazy, ...)` to Shape B
(`.mr_append_write_lazy`). Two options: (a) delete it as part of the
§12 reorg; (b) preserve it in case a bare-lazy-tbl `rebind` path ever
needs it. Not urgent — R CMD check doesn't fail on unused internals —
but worth closing the loop on.

### Consider structured return from `.mr_append_reconcile_schema`

The reconciler currently returns the extended `schema` list with
`attr(, "coerce_to_text")` set when type conflicts were resolved. The
attribute is an implicit contract between the reconciler and its
writer caller. A structured return (`list(schema, coerce)`) would
make the contract explicit and survive future refactors (lazy-tbl
path, additional diff categories) without relying on the attribute
channel. Low priority; the attribute pattern works for v0.1. Flagged
by Task 7's code-quality review.

### Update `../practicum_repos/final_practicum` post-implementation

Invariant 1 is explicitly relaxed for the append-mode stow plan — the
data-frame `stow()`/`grab()` contract flips, and `final_practicum`'s
modeling scripts round-trip data frames through stow/grab. After the
plan lands, grep final_practicum for `stow(` + `grab(` patterns on
tabular values and either (a) wrap them in `launch()` with a `label`
so they flow through Shape B naturally, or (b) convert the affected
values to non-tabular artifacts (e.g. `stow(list(df), name)`) where
per-run accumulation isn't wanted. Outside-launch `grab()` callers get
a lazy tbl with `run_id`/`variant_label` columns instead of a bare
tbl — update downstream `collect()` + column selection accordingly.

Other follow-ups from the plan are tracked in the plan's completion
checklist (`docs/superpowers/plans/2026-04-23-append-mode-stow-impl.md`):
`.mr_reset_append()` user-facing promotion, lazy-path type coercion,
block-level transaction semantics, and the §12 Shape A reorg.

### Block-level transaction semantics for Shape B

Spec §6 "failed runs roll back" is currently implemented per-stow
(each Shape B stow is an independent DuckDB transaction). A mid-block
throw leaves any prior completed stows committed. If block-level
rollback is desired, launch() would wrap the block in a super-txn.
Defer to v0.2.

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
