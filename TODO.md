# modelrunnR TODO

## Revisit under new vision

The package is morphing from `modelrunnR` into the "Code Database
Accumulator" (see [`north_star.md`](north_star.md)). A handful of
existing TODO items predate that direction and may need reframing
once the morph sharpens — not deleted yet because the underlying
concerns still apply, but flagged so they aren't worked
mechanically against the old vision.

Design landed 2026-05-14 in
[`docs/superpowers/specs/2026-05-14-codeinhaler-design.md`](docs/superpowers/specs/2026-05-14-codeinhaler-design.md) —
schema, verbs (`inhale` / `promote` / `export` / `vacuum`), cross-db
model, and the fork plan to a new `codeinhaler` repo. CRAN name
checked clear. modelrunnR v0.1.0 stays frozen once the fork happens;
the items below get re-triaged against that spec rather than against
modelrunnR's old contract.

- **"Hard-remove `ingest()` after one release cycle"** (under
  "Surfaced 2026-04-26"). The old framework's exported-API contract
  is gone; the morph may shake out `ingest()` differently. Don't
  treat "one release cycle" as a hard deadline.
- **"Multi-language script support"** (under "Surfaced 2026-04-22").
  Under "scripts become functions in a code db," the framing shifts
  from "script kind" to "step / function kind." Solution shape may
  follow the new vision rather than the originally-imagined
  `Suggests:`-level integrations.
- **"Map out phases / versioning roadmap"** (under "Surfaced
  2026-04-22"). The L0→L3 reproducibility roadmap in
  `docs/superpowers/specs/2026-05-13-code-snapshot-design.md`
  partly covers this. A `docs/roadmap.md` keyed to DESCRIPTION
  bumps would still help but should reflect the morph direction.
- **Vignette content drift** (multiple items: "ingested" verb,
  batch vignette versioned-shape framing, `mr_variants()` eval=FALSE,
  SQL window-function example, spec ↔ vignette drift). Vignettes
  will likely be rewritten wholesale under the new vision; piecemeal
  fixes have low ROI. Park these as a group; address when the
  vignette set gets a vision-aligned rewrite pass.

## Surfaced 2026-05-14 (from L0 R CMD check pass)

### Non-ASCII characters in `R/dispatch_code.R`

`R CMD check` reports one WARNING: `R/dispatch_code.R` contains em-dashes
(U+2014) in comments at lines 3, 102, 131, 138. Pre-existing — surfaced
but not fixed during L0 (out of scope, framework's "opportunistic
cleanup, unrelated → QUEUE" rule). Quick fix: replace `—` with `--` in
those comments, or escape as `—` per the check's suggestion.

## Surfaced 2026-05-13 (from L0 source-snapshot implementation)

### Garbage-collect orphan `_mr_code` / `_mr_code_helpers` rows

L0 source-snapshot (landed 2026-05-13) writes bytes to `_mr_code` and
`_mr_code_helpers` but never deletes them. When `prune()` drops
`_mr_runs` rows the corresponding `_mr_code` rows become orphans.
They aren't harmful (just disk usage), but the policy should be
decided before v0.2 or once a user hits real disk pressure.

Three plausible shapes:

1. Automatic — every `prune()` cascades to drop orphan `_mr_code` rows
   in the same transaction. Simple mental model: code lives as long
   as a run references it. Cost: prune writes grow.
2. Explicit knob — `prune(gc = TRUE)` or a separate `prune_code()`.
   Useful if a user wants forensic source recovery after a run row is
   removed, but adds a parameter.
3. Background sweep — periodic `mr_gc()` the user calls when storage
   is tight. Lowest run-time cost; lazy housekeeping.

Spec: `docs/superpowers/specs/2026-05-13-code-snapshot-design.md`
"Open questions (deferred)".

## Surfaced 2026-05-13 (from reproducibility direction conversation)

### Code-snapshot / reproducibility roadmap — L0 → L1 → L2 → L3

Spec: `docs/superpowers/specs/2026-05-13-code-snapshot-design.md`. Execute
in this order; each layer is independently useful and ships on its own.

1. **✓ L0 — Source snapshot.** Landed 2026-05-13. `_mr_code` +
   `_mr_code_helpers` content-addressed by `code_hash`; every tracked
   launch (R, inline, SQL, queued) persists script + helper bytes.
   Internal `.mr_load_code()` reader round-trips. GC of orphan rows
   deferred (see entry above).
2. **L1 — Environment lockfile.** Per-run `renv.lock` (or richer
   `installed.packages()` fallback) so the R package env is restorable.
   `renv` as `Suggests:`, not `Imports:` (invariant 3).
3. **L2 — Git-strict mode.** Opt-in `launch(strict = TRUE)`; refuses
   dirty trees or auto-commits to `refs/mr/wip/<run_id>`. Alternative
   to L0 for users willing to commit-before-launch.
4. **L3 — Export.** `mr_export(run_id, path)` produces a compendium
   bundle (source + lockfile + inputs/refs + replay script). Builds on
   L0 + L1.

Don't pre-design L1/L2/L3 in detail until L0 lands — those sketches in
the spec will drift if L0 reshapes assumptions. Write the L1 spec when
L0 lands, etc.

## Surfaced 2026-05-01 (from view-stow design)

### Staleness propagation through views over append-shape inputs

The view-stow path (added 2026-05-01) hashes views by their rendered SQL
text. For an append-shape source, the rendered SQL references the source's
stable append physical name, so appending or replacing chunks does not drift
the view's hash — and `is_stale(view_name)` skips the version-latest check
for append inputs anyway (see `staleness.R:172`, `(name, NA)` recording with
"upstream launch freshness is the authoritative signal"). Net effect:
source-data changes underneath a view-stow do not surface as staleness on
the view or its downstream consumers.

Two plausible directions when this gets prioritized:

1. Hash views by row contents (materialize-then-drop at registration), so
   view identity tracks the rows it would return. Robust but pays a
   registration-time cost on every view stow.
2. Walk the append source's chunk membership at staleness-check time and
   compare against the chunk_hashes recorded on the view's run row. Adds a
   third arm to `.mr_check_inputs()` for "view inputs over append source".

Not blocking for the practicum; flagged here so the weak spot is documented
and the simple SQL-text hash isn't quietly mistaken for content-aware.

## Surfaced 2026-04-29 (from queue+launch unification follow-up)

Surfaced by the final whole-branch review of `fix/queue-audit` after the
unification spec landed (see
`docs/superpowers/specs/2026-04-29-queue-launch-unification-design.md`
and the corresponding plan). All four are low-priority polish — none
block the unification work itself.

### Test `error` and `silent` modes of `modelrunnR.relaunch_nonsuccess` in queue

`tests/testthat/test-queue.R` covers the default `"warn"` mode for
`queue(mr_run(failed_id))` (see
"queue(mr_run(failed_id)) warns under default relaunch_nonsuccess
policy"). Launch tests all three modes for its parallel policy block;
queue should mirror — `options(modelrunnR.relaunch_nonsuccess = "error")`
should make `queue(mr_run(failed_id))` raise; `"silent"` should pass
through. Risk is small (queue's policy block is a copy of launch's), so
this is regression-lock-in coverage, not a hunt for a defect.

### Targeted file-step `code_hash` regression test for `queue(mr_run(file_step_id))`

The spec's "Resolution" §3rd bullet says a file-step source whose file
still exists on disk should hash via `.mr_code_hash(step, list())` —
i.e. hash the *current* file bytes, matching what re-sourcing from disk
would write (`R/queue.R:103-116`). The implementation does this, but
no test exercises it directly: the closest test seeds via inline-step
`launch()` so it only covers the inline branch. Add a test that:
launches a file-step, captures `run_id`, `queue(mr_run(run_id))`,
asserts `q$code_hash` equals `.mr_code_hash(file_path, list())`.
Locks in the contract before drift.

### Roxygen clarification on `queue(mr_run(qid), rebind = ...)` template-fork behavior

`R/queue.R`'s `@param code` block describes the queued-source-with-rebind
case as "the queued row is treated as a template (parallels
`launch(mr_run(qid), rebind = ...)`)" — the parallel doesn't help a
user who hasn't internalized launch's behavior either. One-line
addition: spell out that the queued source remains queued and a fresh
queued row is written with the caller's rebind. Surfaced by the final
unification review.

### Investigate filter-mode test interference

`devtools::test(filter = "launch")` in isolation produces 7 spurious
failures on `test-launch-inline.R:61`, `test-launch-skip-fresh.R:131-133`,
`test-launch-summary.R:9-19`. They don't reproduce when running the
full suite or running each file directly via `testthat::test_file()`.
Likely cause: shared between-file state (test DB or message-capture
state) that the filter-mode runner doesn't reset between files. Not
introduced by recent work — flagged because it makes per-task
filter-mode verification unreliable and could mask future regressions.
Cosmetic; only annoying when reviewing a small subset of tests.

## Surfaced 2026-04-27 (from Phase 1 R CMD check, queue work)

### Test failure in `test-git-info.R:78:3`

Introduced by commit `eddb3a8` (git-context stamping on `_mr_runs`
rows). Fails on main and on `feat/queue` — pre-existing relative to
the queue work, but blocks the framework invariant-1 "R CMD check
clean" gate. Symptom: git context not populating in the test
environment. Likely cause: the test assumes `git` is on PATH and the
working tree is a real repo at the moment the assertion fires; if
the test runs under `devtools::check()`'s isolated build dir, neither
holds.

### `|>` pipe syntax requirement warning in `R/shape_append.R`

`R CMD check` warns the file uses the native `|>` pipe (R 4.1+) but
DESCRIPTION's `Depends:` doesn't pin `R (>= 4.1.0)`. Either bump
DESCRIPTION's R floor or rewrite the pipe(s) in `shape_append.R`.

### Environmental NOTE during R CMD check: "unable to verify current time"

Sandbox has no NTP / outbound network for `R CMD check`'s timestamp
sanity check. Not a code defect; cosmetic on the check log. Ignore
unless it starts blocking CI.

## Surfaced 2026-04-26 (from stow-unification vignette cleanup)

### "ingested" verb still appears in `vignettes/lazy-data.Rmd`

`vignettes/lazy-data.Rmd:45` says "`grab()` ingested the CSV server-side
via DuckDB's `read_csv_auto()` —" describing `grab(source = path)`'s
implicit behavior. The verb "ingested" reads jarringly in a package
that just deprecated `ingest()` (2026-04-26 stow-unification work).
Reword to "`grab()` read the CSV server-side..." or similar; surfaced
by code-quality review of Task 8.

### Update `R/backend_duckdb.R` error messages from `ingest():` to `stow():`

Several error messages in `.mr_ingest_file_to_table()` and `.mr_read_file()`
(R/backend_duckdb.R lines ~77, 84, 93, 109, 113, 122) still prefix
their messages with `ingest():`. Since Task 4 of the 2026-04-26
stow-unification work, these errors are reachable through
`stow(mr_file(...))`, so a user calling the new public verb hits an
error attributed to a deprecated function. Cosmetic but jarring.

Note: the "file not found" case is fine — that error fires earlier
in `.mr_stow_file()` with a `stow():` prefix. The remaining sites are
extension/format errors from the DuckDB-side staging path. Surfaced
by final whole-branch code-quality review of feat/stow-unification.

### Bring `grab(source = path)` into the `mr_file()` vocabulary

Today `grab(name, source = path)` accepts a path string. After the
2026-04-26 stow-unification change, `mr_file()` is the canonical way
to express "this path is a file source." For symmetry, `grab()` should
accept `grab(name, source = mr_file(path))` (or `grab(mr_file(path),
name)`) without breaking the current path-string form. Spec:
docs/superpowers/specs/2026-04-26-stow-unification-design.md
("Non-goals / deferred").

### Hard-remove `ingest()` after one release cycle

`ingest()` is currently a `.Deprecated()` shim that delegates to
`stow(mr_file(source), name)`. After one cycle, drop the export and
the file, and remove `test-ingest*.R`. See "Revisit under new vision"
at top — the old framework's exported-API contract is gone, so this
is no longer a hard cycle gate; the morph may reshape removal timing.

## Surfaced 2026-04-24 (from nested-sweep cookbook design)

### Auto-surface rebind values as columns on append-shape `grab(run = "all")`

Nested sweeps (hyperparameter × k-fold CV) work today via
`mode = "cross"` on `mr_binds()`, but the user must manually stow
rebind values into the metrics tibble as columns:

```r
tibble::tibble(
  alpha = grab("alpha"),        # manual
  fold  = grab("fold"),         # manual
  rmse  = ...
) |> stow("cv_metrics")
```

so that `grab("cv_metrics", run = "all") |> group_by(alpha)` works at
aggregation time. The resolved rebind values are already recorded on
each `_mr_runs.rebinds` JSON entry; they just don't flow into the
append-shape table automatically.

Proposal: `grab(name, run = "all")` on an append-shape name joins the
accumulator against `_mr_runs.rebinds` and surfaces per-run literal /
variant rebind values as columns alongside `run_id` and
`variant_label`. Empty/`[]` rebinds produce no extra columns. No new
exports.

Open design questions:

- **Non-literal rebind kinds.** Variant refs → surface label string;
  `mr_run()` refs → surface run id string; bare data frames → skip (or
  stringify as `data.frame[RxC]` matching the `rebinds` JSON `value`
  field).
- **Collisions.** If the user's stowed df already has a column named
  `alpha`, user columns win; surfaced rebinds get a `_rebind_` prefix
  on collision.
- **Scope.** Apply to `run = "all"` only, or also to explicit
  `run = <id>` / `variant = "x"` (where the resolved rebind columns
  would be constants on the returned frame)?

Not urgent. The cookbook pattern (`vignettes/nested-sweeps.Rmd`) works
today with the explicit stow; this removes three lines of boilerplate
from sweep code once the design questions are answered.

### Skipped-fresh run rows can chain `NA` code_hash across skips

`.mr_record_skipped_fresh` inherits `code_hash` from the most recent
run for this step regardless of status. If the most recent prior row
was itself `skipped_fresh` whose `code_hash` is `NA` (first-time
skip scenario, or a run logged before code_hash was recorded), the
new skipped row also gets `NA`, and subsequent skips inherit `NA`
indefinitely. Flagged by the audit-on-consolidation pass. Narrowest
fix: limit the inheritance query to `status = 'success'` rows.

### Reserved-prefix hole in `.mr_validate_name`

Allowlist now requires `[A-Za-z_][A-Za-z0-9_]*` but nothing rejects
user names starting with `_mr_`, the prefix the package uses for its
own metadata tables (`_mr_runs`, `_mr_versions`, `_mr_append_tables`,
`_mr_code`). A user stowing under `_mr_runs` would collide in
`.mr_guard_namespace` later, with a less-actionable error. Cheap
close: append `&& !startsWith(name, "_mr_")` with an explicit
reserved-prefix message.

### Append-shape lazy-write can emit missing-column SQL after schema drift

`.mr_append_write_lazy` zero-head-collects the lazy tbl, reconciles
schema against the append-shape registry, then builds `INSERT INTO
phys (col_list) SELECT col_list, run_id, label FROM (<body>) AS _src`
using the PRAGMA-driven `user_cols`. If the reconcile path has added
columns to the registry that the lazy tbl's `_src` subquery doesn't
project, DuckDB errors at execution with a "column not found" binder
error. Reachable when a lazy tbl is constructed before `ALTER TABLE
ADD COLUMN` fires for a new column in the same session. Fix: after
reconcile, verify `names(frame_types)` covers all of `user_cols`;
either error early with a clear R-level message or `COALESCE(<col>,
NULL)` the missing columns in the SELECT.

### `.mr_append_user_col_order` fallback is silent

Added 2026-04-24 to drive append-shape lazy-write INSERT column order
from `PRAGMA table_info` rather than parsed `schema_json` key order.
The fallback (catalog query errors or returns 0 rows) silently
reverts to `names(schema)` — exactly the behavior the fix was
trying to remove. Add a `warning()` in the fallback branch so a
regression surfaces.

### Batch-row schema assertion in `.mr_finalize_batch` checks names only

The schema-equality assert before `do.call(rbind, rows_clean)` catches
column-set divergence but not column-type divergence. Can't be type-
tightened today because `.mr_pairs_to_json` legitimately returns
`character` (plain) for empty outputs and `json`-classed for
non-empty; R's `rbind` coerces these silently. A proper fix unifies
`.mr_pairs_to_json`'s return class first (always json-classed, empty
or not), then tightens the assertion to check types too.

### Malformed append-shape output entries silently miss in `.mr_output_matches_name`

The shape discriminator introduced 2026-04-24 returns `FALSE` for a
Shape B entry with `kind = "append_table"` but `logical_name` absent
(evaluates `identical(NULL, name)`). That's a silent miss. Add an
internal warning when `kind == "append_table"` and `is.null($logical_name)`
so corrupt registry state surfaces.

## Surfaced 2026-04-23 (from consolidated-branch audit)

### Lazy-path vs frame-path chunk_hash semantic mismatch

`.mr_append_write_frame` hashes row contents
(`serialize(value[order(value), ], NULL)`); `.mr_append_write_lazy`
hashes the SQL body text. Two runs that produce identical rows via
different SQL get different chunk_hashes; two runs that render to the
same SQL against different upstream data get the same chunk_hash.
`versions()` surfaces these as append-shape versions but the identity
meaning isn't uniform. Pick one: either always materialize and hash
rows (temp-table + `.mr_hash_duckdb_table`), or document that lazy
chunk_hash is SQL-level and frame chunk_hash is row-level. Design
decision, not a bug — flag before v0.1.

### `serialize()`-based chunk_hash is not R-version-stable

Frame-path chunk_hash uses R's `serialize()` format, which may change
with major R upgrades. A append-shape `chunk_hash` recorded on R 4.x may
differ on R 5.x for identical content. Pre-1.0 is fine to leave; fix
pre-release by hashing a canonical representation
(`digest::digest(x, algo = "xxhash64")` on a column-wise sort) or
DuckDB-side via `.mr_hash_duckdb_table` after insert.

### Same `<<- FALSE` bug in `R/launch_sql.R:417`

`R/launch_sql.R:417` uses the same `staging_alive <<- FALSE` pattern as the
old `ingest()` body. Inside `tryCatch({...})`, `<<-` skips the function's
local frame and never updates the guard, so on success `on.exit` fires
a futile DROP TABLE that `try(..., silent = TRUE)` swallows. Not data-
corrupting; just wasted work per call.

Fix is one character: change `<<-` to `<-`. Out of scope for the
2026-04-26 stow-unification work because that branch only touches the
ingest call path. Surfaced by code-quality review of Task 3.

### Versioned-shape extraction to `shape_versioned.R`

Spec §12 calls for `R/shape_versioned.R` to absorb versioned-shape writer
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

### SQL-launch `\bname\b` substitution can chain-collide

`R/launch_sql.R:171-174` applies rebind substitutions iteratively via
word-boundary regex. If an earlier substitution produces a physical
name that matches a later logical name's word boundary, subsequent
passes can double-rewrite. Edge case; real SQL with `name__hex_hash`
physical names won't collide in practice. Consider placeholder
replacement (two-pass: name -> UUID -> physical) for defense.

### Batch vignette reads like versioned-shape semantics

`vignettes/batch-launches.Rmd:164-178` uses `stow(data.frame(), "src")`
producing "versions" — under the new contract this is append-shape, so the
per-call chunks are surfaced as versions via the Option Y amendment,
but the vignette narrative still describes it in versioned-shape terms. Fix:
either switch the vignette source to `ingest()` (keeps versioned-shape) or
rewrite the surrounding prose to name the chunk-per-append model.

## Surfaced 2026-04-23 (from feat/batch-id merge)

### SQL-mode batch_id coverage dropped in merge — needs Shape-B-friendly rewrite

The merge of feat/batch-id into feat/append-mode-stow dropped two SQL-batch
tests ("SQL batch fans out one envelope per version of a rebound input" and
"SQL batch with one bad rebind still records the others") because both
harvested versioned-shape content hashes via `stow(data.frame(), "src")` +
`mr_versions_rows("src")$content_hash`. Under the append-mode contract
`stow(data.frame())` routes to append-shape, so the helper returns zero rows.

R-mode batch_id coverage is retained in `tests/testthat/test-launch-batch.R`.
SQL-mode should get equivalent coverage via `ingest()` for the source data
(which stays versioned-shape) so `mr_hash()`-rebound SQL batches remain tested.

## Surfaced 2026-04-23 (from append-mode stow plan)

### `.mr_stow_lazy` is dead code after Task 9

The versioned-shape lazy-tbl writer (`R/stow_lazy.R :: .mr_stow_lazy`) has zero
callers after Task 9 flipped `stow(tbl_lazy, ...)` to append-shape
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

### Block-level transaction semantics for append-shape

Spec §6 "failed runs roll back" is currently implemented per-stow
(each append-shape stow is an independent DuckDB transaction). A mid-block
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
a concrete use case. See "Revisit under new vision" — the framing may
shift to "step / function kind" under the code-db direction.

### Map out phases / versioning roadmap

No explicit phase plan exists. Write one: what lands in v0.1 (current
R + SQL + batch launches + append-mode stow), v0.2, and further out
(e.g. multi-language above, remote executors, richer diagnostics).
Lets "is this in scope?" triage be a lookup instead of a judgment
call. Target: a short `docs/roadmap.md` keyed to DESCRIPTION version
bumps. See "Revisit under new vision" — partly overlaps with the
L0→L3 reproducibility roadmap.

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

### Test gaps surfaced by audit

- `external_inputs = list(...)` flowing through a SQL launch is in
  scope per spec §8 but not exercised by `test-launch-sql-*`.
- Namespace guard tested only view→table direction; table→view
  reverse is also banned and untested.
- Round-trip stability of `code_hash` for a SQL launch across re-runs
  is implicit in the skip-on-fresh test but not asserted directly.

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

### `stow()` of a lazy `tbl_dbi` falls through to the artifact path

`stow()` dispatches on `is.data.frame(value)`. A `tbl_dbi` / `tbl_sql` /
`tbl_lazy` is not a data frame, so it hits `.mr_stow_artifact` and gets
`qs2::qs_serialize`d as an opaque R object — the stored payload is the
query definition, not the data, and it's useless across sessions once
the connection is gone.

Fix: detect `tbl_dbi` / `tbl_sql` in `stow()` and materialize via
`CREATE TABLE AS` against `mr_con()` without round-tripping through R.
