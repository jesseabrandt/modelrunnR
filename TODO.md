# modelrunnR TODO

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

## Surfaced 2026-04-28 (from queue() audit fixes)

### ✓ Queued-row pickup with caller bindings spawns a new run

Closed 2026-04-29: `launch(mr_run(qid), rebind = ...)` (or
`external_inputs = ...`) against a queued row now warns and spawns
a fresh `run_id` from the queued body with the caller's bindings;
the queued row stays queued. `mr_binds()` fans out into N new runs
under the same rule. `variant_label` inherits from the queued row
unless caller passes `label = ...`. See `R/launch.R` queued branch
and `tests/testthat/test-queue-pickup.R`.

## Surfaced 2026-04-27 (from Phase 1 R CMD check, queue work)

### Test failure in `test-git-info.R:78:3`

Introduced by commit `eddb3a8` (git-context stamping on `_mr_runs`
rows). Fails on main and on `feat/queue` — pre-existing relative to
the queue work, but blocks the framework invariant-2 "R CMD check
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
the file, and remove `test-ingest*.R`. Update `final_practicum` and
any other dependent project before doing this. Invariant 5 (ASK before
removing exports).

## Surfaced 2026-04-25 (from mi_forests setup)

### ✓ In-memory frame → versioned source should be a one-liner

Today `grab(source = path)` only accepts a file path, so a project that
builds its source dataset in R has to write a file first and then point
`grab()` at it. Surfaced in `mi_forests` as ~7 lines of explicit
`arrow::write_parquet()` boilerplate before the `grab(source = ...)`
call could even start.

`ingest(name, path)` has the same path-only constraint. `stow(df, name)`
exists but routes to append-shape under the new contract — wrong shape
for "this is my source dataset, treat it as a versioned input."

Goal: building a data frame in R and registering it as a versioned
named source should be one call, no detour through the filesystem.

Open questions (do not presuppose the parquet-materialization route —
it may interact awkwardly with the source-hash contract):

- **Surface.** `ingest(name, source = function() ...)` overload? Or a
  separate `ingest_frame(name, df)` / `register(name, df)` verb? Or
  extend `grab(source = ...)` to accept a function/frame?
- **Hashing.** `grab(source = path)` keys idempotency on the file's
  content hash. For an in-memory frame the analogue is hashing the
  frame contents directly (R-version-stable hash, see the
  `serialize()`-based chunk_hash item below). Picking the right hash
  primitive matters more than picking the storage format.
- **Shape.** Versioned-shape (so the dataset has a stable identity and
  re-running with identical inputs is a no-op) — not append-shape.
- **Materialization.** Whether the frame lands as a DuckDB table
  written from R, or as a parquet sidecar that DuckDB reads, is an
  implementation detail downstream of the hashing decision. Don't
  lock it in at the API level.

Not urgent. Workaround today: write a temp parquet, `grab(source =
tmp)`, delete. Cleaning this up removes a recurring friction point for
projects whose source data isn't already a file on disk.

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

### ✓ Skip-on-fresh respects per-envelope rebinds

Closed 2026-04-29: verified-and-locked-in. The fix landed in
`6b95c15` (2026-04-24, audit sweep) via the rebind-aware branch of
`.mr_check_inputs`: when the about-to-fire launch has a rebind on a
recorded input name, the check compares the rebound hash against
the prior input's hash rather than against `latest(name)`. So a
sweep where every envelope rebinds (say) `alpha` to a different
literal records different `_mr_runs.inputs` content hashes per
envelope, and staleness flags `input:alpha` for envelopes 2..N
instead of skipping them.

The `vignettes/nested-sweeps.Rmd` `.labels` workaround still works
but is no longer required — could be relaxed in a vignette pass.
Tests in `tests/testthat/test-staleness-rebind.R` lock in the
contract: same step + same label + different rebind values run; same
rebind values skip; `mr_binds()` sweeps under one label run every
envelope.

### Skipped-fresh run rows can chain `NA` code_hash across skips

### Reserved-prefix hole in `.mr_validate_name`

Allowlist now requires `[A-Za-z_][A-Za-z0-9_]*` but nothing rejects
user names starting with `_mr_`, the prefix the package uses for its
own metadata tables (`_mr_runs`, `_mr_versions`, `_mr_append_tables`).
A user stowing under `_mr_runs` would collide in `.mr_guard_namespace`
later, with a less-actionable error. Cheap close: append `&& !startsWith(name, "_mr_")` with an explicit reserved-prefix message.

### ✓ Direct unit test for rebind-aware staleness

Closed 2026-04-29: see `tests/testthat/test-staleness-rebind.R`,
added alongside the verify-and-close pass on the rebind-staleness
TODO above.

(Original note kept below for reference.)

The test-launch-batch updates exercise the new rebind threading
indirectly via batch skip-on-fresh under labeled envelopes. A direct
unit test would lock in the core invariant: seed a run under
`rebind = mr_hash(old_hash)`, stow a newer version of that name,
re-launch under the same pin, assert `skipped_fresh`. Low priority;
the existing suite covers the broad path.

`.mr_record_skipped_fresh` inherits `code_hash` from the most recent
run for this step regardless of status. If the most recent prior row
was itself `skipped_fresh` whose `code_hash` is `NA` (first-time
skip scenario, or a run logged before code_hash was recorded), the
new skipped row also gets `NA`, and subsequent skips inherit `NA`
indefinitely. Flagged by the audit-on-consolidation pass. Narrowest
fix: limit the inheritance query to `status = 'success'` rows.

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

### ✓ Test comments still reference `Shape A` / `Shape B`

The 2026-04-24 rename to `versioned-shape` / `append-shape` covered
user-facing surfaces (spec, framework, README, NEWS, getting-started
vignette, this file) but deferred the ~20 test files under
`tests/testthat/` that reference the old names in comments and
`test_that()` descriptions. Closed 2026-04-24: bulk sed rename across
29 test files.

## Surfaced 2026-04-23 (from consolidated-branch audit)

### ✓ Append-shape non-interactive provenance gap

Closed 2026-04-29. Chunk records now land in a dedicated
`_mr_append_chunks` table at stow-commit time, inside the same
DuckDB transaction as the row INSERT. A process crash between stow
commit and the later `_mr_runs.outputs` write no longer orphans the
chunk identity: `versions(name)` and `mr_hash()` resolution read
from the new table, which is durably committed alongside the data.

### ✓ `.mr_append_chunk_entries` replaced by keyed `_mr_append_chunks` queries

Closed 2026-04-29. Read paths (`.mr_append_run_id_for_chunk_hash`,
`.mr_append_latest_run_id`, `.mr_append_chunk_hash_for_run`,
`versions(name)` Shape B branch) now hit the keyed
`_mr_append_chunks` table instead of scanning every `_mr_runs.outputs`
JSON. The old `.mr_append_chunk_entries` helper was deleted.

### ✓ Ghost chunk_hashes after `prune(name, by = "run")`

Closed 2026-04-29. `.mr_prune_shape_b_one()` now cascades the by-run
prune into `_mr_append_chunks` inside the same `dbBegin`/`dbCommit`
fence, so `versions(name)` and `mr_hash()` resolution don't surface
entries for runs whose rows we just removed.

### ✓ DDL auto-commit around `_mr_append_tables` first-write

Closed 2026-04-29. Split `.mr_append_ensure_table` into a DDL-only
`.mr_append_create_physical_table` (called BEFORE `dbBegin`, so
DuckDB's DDL auto-commit is explicit) and a registry-only
`.mr_append_insert_registry_row` (called INSIDE `dbBegin`/`dbCommit`).
Both `.mr_append_write_frame` and `.mr_append_write_lazy` updated.
ALTER TABLE inside `.mr_append_reconcile_schema` has the same
auto-commit shape but is a separate concern (schema-drift recovery)
— left for a follow-up.

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

### ✓ SQL-launch records append-shape chunk_hash on `_mr_runs.inputs`; R-launch records `NA`

Closed 2026-05-01: R-launch's `grab()` on a Shape B name now records
the resolved chunk_hash on `_mr_runs.inputs`, mirroring SQL-launch.
`.mr_check_inputs` is shape-aware (consults `_mr_append_chunks` for
Shape B names) so a downstream consumer goes stale when upstream
appends a new chunk. Tests: `tests/testthat/test-staleness-append.R`.

### `serialize()`-based chunk_hash is not R-version-stable

Frame-path chunk_hash uses R's `serialize()` format, which may change
with major R upgrades. A append-shape `chunk_hash` recorded on R 4.x may
differ on R 5.x for identical content. Pre-1.0 is fine to leave; fix
pre-release by hashing a canonical representation
(`digest::digest(x, algo = "xxhash64")` on a column-wise sort) or
DuckDB-side via `.mr_hash_duckdb_table` after insert.

### ✓ Type-coerce-to-TEXT is session-TZ-dependent for POSIXct

`R/shape_append.R:122-127` — `as.character(POSIXct)` renders in the
session's TZ. Two runs in different TZs with the same instant coerce
to different TEXT values, breaking reproducibility for schema drift
involving timestamps. Fix: for POSIXct specifically, use
`format(x, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")`.

### ✓ `schema_json` column order depends on jsonlite key preservation

`fromJSON(..., simplifyVector = FALSE)` returns a named list; JSON
object key order is not guaranteed across library versions. `names(schema)`
is used to drive INSERT column order on the lazy-write path, so a
jsonlite upgrade that reorders keys could silently misalign
`INSERT ... SELECT`. Fix: align incoming columns to DuckDB physical
column order via `PRAGMA table_info(...)` rather than relying on
parsed JSON order.

### ✓ `prune(by = "run")` builds SQL `IN (...)` lists inline

`R/prune.R` uses `quote_list(ids)` to embed run ids as literals in
`IN (...)` clauses. Today's run_id format is alphanumeric (package-
generated) so no injection path, but the SQL body grows unbounded for
large prune lists. Fix: build a DuckDB temp table of ids and
`DELETE ... WHERE _mr_run_id IN (SELECT id FROM tmp)`.

### ✓ `.mr_validate_name` allowlist is permissive

`R/validate.R:29` blocks `/`, `\`, `..`, and control chars. Permits
spaces, `$`, `@`, commas, most punctuation. Combined with `gsub`
replacement in `launch_sql.R`, behavior under undefined PCRE
backreferences (`$1`, `\1`) is technically unspecified. Current R
is benign; defensive tighten to `^[A-Za-z_][A-Za-z0-9_]*$` plus
`gsub(..., fixed = TRUE)` on the substitution.

### ✓ Staging-table orphan on commit failure

`R/launch_sql.R:406` (and adjacent in `R/ingest.R`) set
`staging_alive <<- FALSE` before `DBI::dbCommit`. If commit fails,
the on.exit handler doesn't drop the staging table. Move the flag
flip to after the `dbCommit` returns. Pre-existing pattern, not new
to the append-mode branch.

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

### ✓ Helper dedup: `.mr_new_run_id` / `.mr_new_batch_id`

`R/launch.R:332-342` — six-line near-duplicates differing only in
prefix. One helper: `.mr_new_id(prefix)`.

### ✓ `_mr_runs.outputs` shape-discriminator duplicated across files

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

### Update `../practicum_repos/final_practicum` post-implementation

Invariant 1 is explicitly relaxed for the append-mode stow plan — the
data-frame `stow()`/`grab()` contract flips, and `final_practicum`'s
modeling scripts round-trip data frames through stow/grab. After the
plan lands, grep final_practicum for `stow(` + `grab(` patterns on
tabular values and either (a) wrap them in `launch()` with a `label`
so they flow through append-shape naturally, or (b) convert the affected
values to non-tabular artifacts (e.g. `stow(list(df), name)`) where
per-run accumulation isn't wanted. Outside-launch `grab()` callers get
a lazy tbl with `run_id`/`variant_label` columns instead of a bare
tbl — update downstream `collect()` + column selection accordingly.

Other follow-ups from the plan are tracked in the plan's completion
checklist (`docs/superpowers/plans/2026-04-23-append-mode-stow-impl.md`):
`.mr_reset_append()` user-facing promotion, lazy-path type coercion,
block-level transaction semantics, and the §12 versioned-shape reorg.

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

### ✓ `mr_envelopes()` doesn't warn on duplicate `.label` across envelopes

Two envelopes labeled `"baseline"` both run and both stamp the same
label, breaking the "label is a tracked variant thread" invariant
that relaunch relies on. Likely a `warning()` (not an error: there
are valid reasons to deliberately repeat a label, e.g. seeded reruns).

### ✓ `do.call(rbind, rows)` is brittle if row schema diverges

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

### ✓ `.mr_check_inputs` ignores rebind when comparing to "current latest"

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

### ✓ `gsub` replacement string in rebind substitution isn't escaped

`R/launch_sql.R` `.mr_launch_sql` uses
`gsub(pat, .mr_quote_ident(physical_for[[nm]]), rendered_body, perl = TRUE)`.
A replacement string containing `\`, `\1`, or `$1` would be
reinterpreted by `gsub`. Currently safe (logical names are validated;
physical names are `name__hex_hash`), but a defensive
`stringi::stri_replace_all_fixed` or escape pass would future-proof.

### ✓ DRY skipped-fresh and nested-launch helpers

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

### ✓ Tighten `.mr_validate_name` allowlist

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

### ✓ 1. `rebind = list(<name> = <df>)` pollutes the target's version history

Closed 2026-05-01 via option (ii) — `is_rebind` flag on `_mr_versions`.
Bare-value rebinds still write a row but with `is_rebind = TRUE`; the
latest-view filter excludes those rows so naked `grab(name)` returns
the real upstream. `versions(name)` shows rebinds by default with
`include_rebinds = FALSE` to filter; `mr_hash()` still resolves rebind
hashes. Tests: `tests/testthat/test-rebind-is-rebind.R`.

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

### ✓ 3. `stow()` signature-swap guard is too narrow

`stow()` went value-first: `stow(value, name)`. The guard only fires
when `name` is missing AND `value` is a length-one character vector.
The old `stow("ridge_preds", df)` pattern has `name` present (the data
frame), so the guard skips and the call fails later with a
less-useful error from `.mr_validate_name(<data.frame>, ...)`.

Fix: widen the guard to also detect
`is.character(value) && length(value) == 1L && is.data.frame(name)`
(and similar for artifact payloads) and point at the swap.
