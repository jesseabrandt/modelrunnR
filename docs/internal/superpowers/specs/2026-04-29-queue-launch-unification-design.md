# Unifying `queue()` with `launch()` — shared dispatch + relaunch refs

**Status:** design, drafted 2026-04-29
**Scope:** Two changes that go together. (1) Extract the first-argument
dispatch + body-capture logic shared between `launch()` and `queue()` into a
single internal helper, with acceptance policy as a parameter. (2) Use that
to broaden `queue()`'s acceptance set from `{inline, .R file}` to `{inline,
.R file, mr_label(), mr_run()}`, matching launch's R-mode dispatch surface.
SQL queueing remains out of scope for this round.
**Depends on:** existing `launch()` machinery (`R/launch.R`,
`R/launch_one.R`, `R/launch_queued.R`); the relaunch resolvers
`.mr_resolve_relaunch()` and `.mr_resolve_relaunch_run_id()` (already in
`R/launch.R`); existing `queue()` surface (`R/queue.R`).

**Supersedes (partial):** the "Out of scope (v1)" item in
[`2026-04-26-queue-design.md`](2026-04-26-queue-design.md) that rejected
`queue(mr_run(id))` and `queue(mr_label(...))` on coherence grounds. That
argument was wrong (see Motivation §"Why the original cut was wrong").

## Motivation

The framing for this change is unification. `queue()` is "`launch()` minus the
execution" — same dispatch ladder, same body capture, same row write. Today
they share the row-write helper (`.mr_write_run_row()`) but each implements
its own first-argument dispatch with subtly different acceptance sets. The
fix is to make more of the machinery actually shared, which then makes the
acceptance broadening a one-line policy change.

### The user-facing gap

`final_practicum/qmd/concurrent_price.qmd` runs five models × two variants
(pure-fundamentals + placebo) × N rolling windows. The placebo runs use
`launch(mr_label("cprice_<model>__pf"), rebind = mr_binds(...))` to take the
labeled body, swap the panel from `cprice__pf_sample` to
`cprice__pbo_sample`, and fan out across windows
(concurrent_price.qmd:325–337 and parallel sections for lasso / rf / xgb /
nn).

The user wants the queue equivalent — stage the whole sweep, drain it from
`furrr` / `tsp` later — but `queue(mr_label("cprice_ridge__pf"), rebind =
mr_binds(...))` errors today on the first argument. The workaround is to
re-supply the body inline, which defeats the point of having a labeled
pipeline.

### Why the original cut was wrong

The 2026-04-26 queue spec rejected `mr_label()` / `mr_run()` first-args with
"the row already exists; what would re-queueing produce?" That argument
collapses on inspection: `launch(mr_run(id))` against a finalized row
already spawns a *new* run from that body. Queueing that same operation —
"stage a future run that uses this body" — is the deferred form of
something `launch()` already does. The resolved body becomes the queued
snapshot, with a fresh `run_id`.

The only genuinely circular case is `queue(mr_run(qid))` where `qid`'s own
status is `"queued"` *and* no rebind is supplied. That one stages a copy of
something already staged. Reject that specific case; everything else is
coherent.

### Why DRY first

The acceptance change is small (one accept-set flip). The reason to extract
a shared dispatcher first is that `launch()` and `queue()` already duplicate:

- inline-mode detection (`is.call(x) && identical(x[[1]], as.name("{"))`)
- inline-mode body capture (deparse → hash → `<inline:hash>` step)
- file-mode body capture (file.exists → normalizePath → readLines →
  `.mr_code_hash`)
- ref-arg detection and rejection messages
- SQL-arg detection and rejection messages

`launch.R` and `queue.R` re-implement the same shape with slightly
different rejection messages. Sharing the dispatcher means the queue
acceptance change is a parameter flip, not a new code path, and any future
dispatch addition (a hypothetical `mr_pipeline()` or whatever) lights up in
both verbs at once.

## Target usage

The cprice placebo flow becomes:

```r
# Pure-fundamentals (unchanged): one launch per window via mr_binds().
launch(
  code = { ... model body ... },
  rebind = mr_binds(test_year = windows$test_year, ...,
                    cprice_sample = list(mr_variant("cprice__pf_sample"))),
  label = "cprice_ridge__pf"
)

# Placebo: queue the same body for deferred execution.
queue(
  code = mr_label("cprice_ridge__pf"),
  rebind = mr_binds(test_year = windows$test_year, ...,
                    cprice_sample = list(mr_variant("cprice__pbo_sample"))),
  label = "cprice_ridge__pbo"
)
```

The five models × placebo runs become a single staging block, drained later
by whatever consumer the user picks (serial loop, `furrr`, `tsp`, HPC).

```r
# Stage a re-run of a specific historical run with new bindings
queue(mr_run(prev$run_id), rebind = list(threshold = 0.9))

# Or just stage a re-run as-is — body from history, no rebind change
queue(mr_run(prev$run_id))
```

## Part 1: shared first-argument dispatcher

### New internal: `.mr_dispatch_code_arg()`

Lives in a new file `R/dispatch_code.R`. Signature:

```r
.mr_dispatch_code_arg <- function(code, script_expr,
                                  accept_refs = character(0),
                                  accept_sql  = FALSE,
                                  caller      = "launch")
```

**Inputs:**
- `code` — the value bound to the caller's `code` parameter.
- `script_expr` — the unevaluated expression captured by the caller via
  `substitute(code)` (so a literal `{...}` block can be detected).
- `accept_refs` — character vector, subset of `c("label", "run")`. Names of
  ref kinds the caller will accept as a first argument. `mr_hash()` is never
  accepted; `mr_variant()` / `mr_as_of()` aren't accepted as first-args
  anywhere today.
- `accept_sql` — `TRUE` if the caller accepts `.sql` paths and `mr_sql()`.
- `caller` — `"launch"` or `"queue"`, used only to compose error messages.

**Returns** a list:
```r
list(
  kind        = "inline" | "file" | "sql_inline" | "sql_file" |
                "ref_label" | "ref_run",
  inline_mode = <logical>,             # TRUE for kind == "inline"
  step        = <character>,           # "<inline:hash>" or normalized path
  code_body   = <character>,           # body text (verbatim or from disk
                                       # / snapshot, depending on kind)
  code_hash   = <character> | NULL,    # set for non-relaunch kinds; NULL
                                       # for ref kinds (caller computes
                                       # post-execution for launch, or
                                       # uses the resolver's value)
  ref         = <list> | NULL          # for ref_label / ref_run: the
                                       # resolver's return value, with
                                       # `$expr`, `$variant_label`,
                                       # `$status` (run only), etc.
)
```

**Behavior** mirrors what `launch()` does today, just consolidated:

1. **Inline mode** (`script_expr` starts with `{`): deparse to `code_body`,
   hash to derive `step = "<inline:hash>"`, compute `code_hash` via
   `.mr_code_hash_inline(code_body, list())`. Return.
2. **`mr_sql()` ref**: if `!accept_sql` reject with "<caller>(): SQL
   staging via mr_sql() is out of scope (v1)." (queue). If `accept_sql`,
   return `kind = "sql_inline"` with the SELECT body in `code_body` and
   leave further dispatch to the caller (launch routes into the SQL
   launcher).
3. **Other refs** (`mr_label`, `mr_run`, `mr_hash`): match against
   `accept_refs`. Reject mismatches with the existing message shape. For
   accepted refs, call `.mr_resolve_relaunch()` (label) or
   `.mr_resolve_relaunch_run_id()` (run); fold the resolver's `step` /
   `code_body` / `expr` / `variant_label` / `status` into the return. Set
   `kind = "ref_label"` / `"ref_run"`.
4. **Character path**: extension check. `.sql` paths gated on `accept_sql`;
   non-`.sql` paths existence-checked, normalized, read into `code_body`,
   `code_hash` via `.mr_code_hash(step, list())`. Return
   `kind = "file"` (or `"sql_file"`).

The dispatcher does **not** apply caller-side policy that's specific to
launch's runtime semantics:
- It does not run the `relaunch_nonsuccess` warn/error policy on
  `mr_run()` — that's a launch concern (queue does too, see Part 2). The
  dispatcher returns `ref$status` so callers can apply their own policy.
- It does not check the queued-source-status circular case — that's
  queue-specific (Part 2).

### Caller-side changes

`launch()` (`R/launch.R`):
- Replace the inline-mode / SQL-arg / ref-arg / file-arg ladder
  (currently L201–342) with one call to `.mr_dispatch_code_arg(code,
  script_expr, accept_refs = c("label","run"), accept_sql = TRUE,
  caller = "launch")`.
- Branch on the returned `kind` for the few launch-specific subsequent
  steps (SQL path dispatch, queued-row pickup, relaunch-nonsuccess
  warn/error policy).
- Net effect: `launch()` shrinks; behavior is byte-identical for end users.

`queue()` (`R/queue.R`):
- Replace the inline / file / ref-rejection ladder (currently L75–109)
  with one call to `.mr_dispatch_code_arg(code, script_expr, accept_refs =
  c("label","run"), accept_sql = FALSE, caller = "queue")`.
- After dispatch, apply queue's own policy (Part 2).

### Refactor invariant

Part 1 ships as a pure refactor: no user-visible behavior change, all
existing tests pass without modification, error messages stay
byte-identical (or close enough that the diff is a deliberate consolidation
documented in NEWS). Part 2 builds on top.

## Part 2: broaden `queue()`'s acceptance set

With Part 1 in place, broadening is a one-line accept-set change at
`queue()`'s call site (`accept_refs = character(0)` → `accept_refs =
c("label", "run")`) plus a small post-dispatch policy block.

### Acceptance matrix

| First arg | Today | After |
|---|---|---|
| `{ ... }` inline | accept | accept |
| `.R` file path | accept | accept |
| `.sql` file / `mr_sql()` | reject | reject (still out of scope) |
| `mr_hash(...)` | reject | reject (unchanged — hashes are content references, not pipelines) |
| `mr_label("x")` where some non-queued row exists under x | reject | accept — body resolved from the most-recent non-queued row |
| `mr_label("x")` where only queued rows exist under x, **no** rebind | reject | reject (genuinely circular — same shape as `mr_run(qid)` below) |
| `mr_label("x")` where only queued rows exist under x, **with** rebind | reject | accept — most-recent queued row treated as a template |
| `mr_run(id)` where source status ∈ {`success`, `error`, `skipped_fresh`, `interactive`} | reject | accept — body resolved like `launch(mr_run(id))` |
| `mr_run(qid)` where source status = `"queued"`, **no** rebind | reject | reject (genuinely circular) |
| `mr_run(qid)` where source status = `"queued"`, **with** rebind | reject | accept — queued row treated as a template, mirrors `launch(mr_run(qid), rebind=...)` |

`launch(mr_label("x"))` continues to reject queued-only labels — picking up
a queued row by label would silently orphan the queued row, so direct
pickup must go through `launch(mr_run(id))`. Queue diverges because it
isn't draining; it's templating, and the same row body is a perfectly
valid template source whether or not the row has executed.

### Resolution

The dispatcher already returns the resolver's full triple (`step`,
`code_body`, `expr`) plus `ref$variant_label` and `ref$status`. Queue uses:

- `step` and `code_body` as the queued row's frozen body (same as inline /
  file dispatch).
- `code_hash` computed to match what `launch()` would have written for
  the same dispatch:
  - `mr_label`/`mr_run` resolving to an inline source step → hash over
    the snapshot via `.mr_code_hash_inline(code_body, list())`.
  - `mr_label`/`mr_run` resolving to a file-step source where the file
    exists on disk → hash over the file via `.mr_code_hash(step, list())`
    (matches what re-sourcing from disk would write).
  - `mr_label`/`mr_run` resolving to a file-step source where the file
    is gone (resolver fell back to the snapshot, returned non-NULL `expr`)
    → hash over the snapshot via `.mr_code_hash_inline(code_body, list())`,
    so the queued row stays internally consistent with the body it
    actually carries.
- `ref$variant_label` for label inheritance (see below).
- `ref$status` for the queued-source policy block.

### Label inheritance

Mirror `launch()`'s rule (R/launch.R:296–303): if the caller passed
`label`, use it. Otherwise:
- For `queue(mr_label("x"), ...)`, inherit `"x"`.
- For `queue(mr_run(id), ...)`, inherit the resolved row's `variant_label`
  (may be `NA`).

This keeps cprice's placebo flow correct: `queue(mr_label("cprice_ridge__pf"),
label = "cprice_ridge__pbo")` writes queued rows under the new label, just
as `launch()` does today.

### Non-success source policy

`launch(mr_run(id))` against a non-success source row warns by default,
configurable via `options(modelrunnR.relaunch_nonsuccess)`. `queue()`
applies the same policy with the same option key — staging a copy of a
failed run's body silently is just as user-hostile as relaunching it
silently. The check fires on `kind == "ref_run"` only — label resolution
prefers non-queued rows when they exist and only ever lands on a queued
row when no other rows exist under the label, in which case the queued-
source policy block (below) applies instead.

### Queued-source policy block

Queue's policy on a queued source applies symmetrically to `kind ==
"ref_run"` (queued source row) and `kind == "ref_label"` (label whose
only rows are queued):

- **No rebind supplied:** error. The `ref_run` message names the
  specific `run_id`; the `ref_label` message names the label and points
  at `launch(mr_run(id))` for draining (since `launch(mr_label(...))`
  rejects queued-only labels by design).
  > ref_run: `queue(mr_run('<qid>')): the source row is itself queued and no rebind was supplied. Re-queueing a queued run with no changes is circular. Either supply rebind = ... to stage a variant, or drain the queued row first via launch(mr_run('<qid>')).`
  > ref_label: `queue(mr_label('<x>')): label '<x>' has only queued rows and no rebind was supplied. Re-queueing a queued template with no changes is circular. Either supply rebind = ... to stage a variant, or drain a queued row first via launch(mr_run(id)).`
- **Rebind supplied:** accept. Treat the queued row's body as a template
  exactly the way `launch(mr_run(qid), rebind=...)` does (launch.R:362–
  383). The queued source remains queued for someone else to drain; the
  new queued row is independent.

### What gets written

Same shape as today's `queue()`-of-inline / `queue()`-of-file: a row in
`_mr_runs` with `status = "queued"`, frozen `step` / `code_body` /
`code_hash` / `rebinds` / `batch_id` / `duckdb_seed`, blank session info
(filled at pickup), `inputs` / `outputs` / `helpers` / `external_inputs`
populated per the existing post-audit rules. No new columns, no schema
change.

Pickup behavior (`launch(mr_run(qid))`) is unchanged — the queued row
looks like any other queued row to the pickup path.

## Out of scope (still)

- **SQL queueing.** `queue(mr_sql(...))` and `queue("x.sql")` continue to
  reject. Two reasons: (a) the user's current workflow doesn't need it
  (cprice is R-mode), (b) the read side is real work (`launch_queued.R`
  doesn't speak SQL — a sibling `.mr_pickup_queued_sql_run()` would need
  to mirror the SQL launcher). Defer to a follow-up spec.
- **`mr_hash()` first-arg.** Hashes are content references, not
  pipelines. Same rejection in both verbs.
- **Worker / scheduler / `drain_queue()`.** Unchanged from the original
  queue design — composition with `furrr` / `tsp` / HPC is the user's call.
- **Pruning queued rows.** Still a follow-up.

## Verification

Pre-merge checklist (per framework completion criteria):

- `R CMD check` clean.
- All existing `test-launch*.R` and `test-queue*.R` pass without
  modification (Part 1 is byte-equivalent on observed behavior; Part 2
  only opens previously-rejected paths).
- New test coverage:
  - `queue(mr_label("x"))` writes a queued row whose `code_body` matches
    what `launch(mr_label("x"))` would have run (modulo execution-time
    columns).
  - `queue(mr_label("x"), rebind = mr_binds(...))` writes N queued rows
    under one batch_id with envelope-specific rebinds.
  - `queue(mr_run(id))` against a `success` source writes a fresh queued
    row; pickup via `launch(mr_run(new_qid))` runs the right body.
  - `queue(mr_run(qid))` against a `queued` source with no rebind errors
    with the circular-source message.
  - `queue(mr_run(qid))` against a `queued` source *with* rebind
    succeeds, leaves the source queued, writes a new queued row.
  - `queue(mr_run(failed_id))` warns under default
    `modelrunnR.relaunch_nonsuccess`; errors under `"error"`; silent
    under `"silent"`.
  - Label inheritance: `queue(mr_label("x"))` with no `label =` writes
    `variant_label = "x"`; with explicit `label = "y"` writes `"y"`.
  - File-step relaunch: `queue("fit.R")` and `queue(mr_run(id))` where
    the source step is `fit.R` both freeze the file's *current* bytes
    into `code_body`; pickup applies the existing drift / re-source rules.
- `final_practicum/qmd/concurrent_price.qmd` placebo sections can be
  rewritten from `launch(mr_label(...))` to `queue(mr_label(...))` and
  drain cleanly via a serial `purrr::walk(qs$run_id, ~ launch(mr_run(.x)))`
  loop. (Smoke test, not a unit test; run by hand before merge.)

## Implementation order

1. **Refactor (Part 1).** New file `R/dispatch_code.R` with
   `.mr_dispatch_code_arg()`. Rewire `launch()` and `queue()` to call it.
   No accept-set changes yet. Tests stay green.
2. **Acceptance broadening (Part 2).** Flip queue's `accept_refs`. Add
   the queued-source policy block. Add label-inheritance and
   non-success-warn handling. Add new tests.
3. **Docs.** Update `queue()`'s roxygen to document the new accepted
   first-arg shapes. NEWS bullet under the next version. Vignette gets
   a short "queueing a relaunch" note next to the existing batch
   example.

SQL queueing follows in a later spec when needed.
