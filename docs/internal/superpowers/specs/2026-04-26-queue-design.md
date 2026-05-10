# `queue()` — register a run without executing it

**Date:** 2026-04-26
**Status:** design

**Scope:** New exported verb `queue()` that captures `(step, code_body,
code_hash, rebinds, label, batch_id)` to `_mr_runs` with `status = "queued"`
and does not execute. Existing `launch(mr_run(id))` is the pickup point and
drains queued rows in place. New status value `"queued"` joins the existing
set (`success`, `error`, `skipped_fresh`, `interactive`). No new columns on
`_mr_runs`. No worker, no scheduler, no parallelism — those are the user's
concern.

**Depends on:** existing `launch()` machinery (`R/launch.R`,
`R/launch_one.R`, `R/launch_batch.R`); `slate_run()` first-arg reference
support per [`2026-04-25-launch-by-run-id-design.md`](2026-04-25-launch-by-run-id-design.md);
`slate_binds()` rebind expansion per
[`2026-04-19-batch-launch-design.md`](2026-04-19-batch-launch-design.md).

**Naming:** This spec uses the current `mr_*` symbol names (`mr_run`,
`mr_binds`, etc.) — the package's status quo. The
[`2026-04-26-launchslate-rename-design.md`](2026-04-26-launchslate-rename-design.md)
spec proposes a rename to `slate_*`; both `modelrunnR` and `launchslate` are
live candidates and a decision is deferred. If the rename is adopted, the
references in this file sweep along with the rest of the codebase. Naming is
not load-bearing for the design.

## Motivation

Today `launch()` registers a run and executes it in one step. There are
workflows where the user wants the registration without the execution:

- **Stage many runs, kick them off later.** Build up a list of configurations
  during interactive exploration; execute them as a batch when ready.
- **Hand off execution to something that isn't this R session.** A different
  `Rscript -e ...` invocation, a `future`-backed worker pool, a container-level
  job runner like `tsp`, an HPC submit script. Whatever the consumer is,
  modelrunnR doesn't need to know — it just needs to emit run rows the consumer
  can pick up by id.
- **Reproduce a queued plan later.** A queued run is a complete record of what
  *would* have run. Picking it up later (possibly after code on disk has
  changed) executes the snapshot, not whatever the file says now.

The package already has the consumer half: `launch(mr_run(id))` re-executes a
stored run by `run_id`, sourcing from disk for file steps and from
`_mr_runs.code_body` for inline steps. The missing piece is the writer: a verb
that records the same row a successful `launch()` would record, minus
execution.

The fix is small. One verb, one new status value, no schema migration, no
runtime — and parallelism / scheduling stay out of the package entirely.
Composing with `future`/`furrr`/`tsp`/HPC submitters is the user's call.

## Target vignette snippet

```r
library(modelrunnR)

# Stage a single run — returns invisible 1-row tibble, status = "queued"
q <- queue({
  fit <- glmnet::glmnet(grab("x"), grab("y"), alpha = 0.5)
  stow(fit, "model")
})
q$run_id   # → "run_20260426_..."
q$status   # → "queued"

# Stage a batch — returns invisible N-row tibble, all status = "queued"
qs <- queue({
  fit <- glmnet::glmnet(grab("x"), grab("y"), alpha = grab("alpha"))
  stow(fit, "model")
}, rebind = mr_binds(alpha = c(0.1, 0.5, 1.0)))

# Pick up later — anywhere, any process, serial or parallel.
# launch(mr_run(id)) is the existing relaunch path; it now also drains
# queued rows in place.
launch(mr_run(q$run_id))                                  # serial
purrr::walk(qs$run_id, ~ launch(mr_run(.x)))              # serial loop
furrr::future_map(qs$run_id, ~ launch(mr_run(.x)))        # parallel via future

# Or hand off from the shell, no R-side coordination:
# $ tsp Rscript -e 'modelrunnR::launch(modelrunnR::mr_run("run_..."))'
```

## API surface

### `queue(code, ..., rebind = NULL, label = NULL)`

One new export. First-arg shape mirrors `launch()`'s in-scope subset:

- **`code`** — a braced expression (inline pipeline) **or** a file path string
  (file step). Same dispatch rules as `launch()`. SQL string dispatch (the
  `launch_sql()` path) is **out of scope for v1** — see §Out of scope.
- **`rebind`** — `NULL` (single run) or a `mr_binds()` object (batch). Same
  semantics as `launch(rebind = ...)`: scalar `rebind` writes one row, batch
  `rebind` writes N rows under one `batch_id`.
- **`label`** — optional `variant_label`, same as `launch(label = ...)`.

`...` reserved for future arguments (matches `launch()`'s signature shape).

**Returns:** invisible tibble shaped like `launch()`'s return — one row for a
scalar call, N rows for a batch. All rows have `status = "queued"`.

**Out-of-scope first args:** `queue(mr_run(id))`, `queue(mr_label(...))`,
`queue(mr_hash(...))`. Re-queueing an already-stored run is incoherent —
the row already exists; what would re-queueing produce? Errors with a clear
message in v1; revisit if a real workflow demands it.

### No other exports

No `unqueue()`, no `requeue()`, no `queue_status()` summary view, no
`drain_queue()` worker. Users introspect via `runs()` (which already shows all
statuses) and clean up via `prune()` or direct SQL.

## Behavior

### What `queue()` writes

`queue()` populates `_mr_runs` with everything `launch()` writes **except** what
only execution produces or observes about its host. Concretely, against the
actual `_mr_runs` schema (see `R/schema.R`):

| Column                                 | Written at queue time?                 |
|----------------------------------------|----------------------------------------|
| `run_id`                               | yes                                    |
| `step`                                 | yes                                    |
| `status`                               | yes — `"queued"`                       |
| `code_body`                            | yes — see file-step note below         |
| `code_hash`                            | yes — see file-step note below         |
| `rebinds` (JSON)                       | yes (`"[]"` if none)                   |
| `variant_label`                        | yes (if provided)                      |
| `batch_id`                             | yes (batch only)                       |
| `duckdb_seed`                          | yes (if provided)                      |
| `inputs` (JSON)                        | `"[]"` — resolved at pickup            |
| `outputs` (JSON)                       | `"[]"` — set at pickup                 |
| `external_inputs` (JSON)               | yes — `queue(external_inputs=)` (post-audit revision; see below) |
| `helpers` (JSON)                       | `"[]"` — set at pickup                 |
| `started_at`                           | NA — set at pickup                     |
| `duration_ms`                          | NA — set at pickup                     |
| `hostname`, `os`, `arch`, `r_version`  | NA — set at pickup                     |
| `n_cpu`, `total_ram_bytes`, `free_ram_bytes` | NA — set at pickup               |
| Other session-context columns          | NA — set at pickup                     |

Rationale for the NAs: session-context columns describe *where the run
executed*, which is unknown at queue time (the consumer may be on a different
host). Inputs / helpers are resolved by parsing-and-executing the body, which
is the work `queue()` declines to do.

**Inputs are not statically pre-resolved at queue time.** Inputs come from
`grab()` calls inside the body and are resolved when the body executes. This
matches existing `launch()` semantics and keeps `queue()` as a thin recorder.

**Post-audit revision (2026-04-28): `external_inputs` accepted at queue time.**
The original spec deferred `external_inputs` to pickup. The audit found this
left users with no way to declare external file dependencies on queued rows
(the pickup branch in `launch.R` didn't forward the caller's `external_inputs`
either, so neither queue-time nor pickup-time worked). Resolution: `queue()`
gains an `external_inputs = NULL` argument with the same shape and contract
as `launch(external_inputs = ...)`. Files are validated and hashed at queue
time (missing files error before any row is written). Pickup reads the
declarations off the row, re-resolves so recorded hashes reflect what the
body saw at pickup, and writes them back. The `launch(mr_run(qid),
external_inputs = ...)` form warns and ignores the caller's value, mirroring
the same treatment for `rebind`.

### Inline vs. file-step capture

For **inline steps** (`queue({ ... })`), the braced expression is captured
verbatim into `code_body` at queue time. Pickup parses and executes that
captured expression — it cannot have changed between queue and pickup. The
`code_hash` is the hash of the captured body (no helpers for inline code).

For **file steps** (`queue("fit.R")`), there is a real choice — `launch()`'s
existing relaunch path (per `2026-04-25-launch-by-run-id-design.md`)
**re-sources from disk if the file exists**, falling back to the stored
snapshot only if the file is gone. Two consequences for queueing:

1. **Snapshot-and-warn-on-drift.** `queue("fit.R")` captures the file's
   current bytes into `code_body` and `code_hash` at queue time, like `launch()`
   does for any file step. When `launch(mr_run(id))` picks the queued row up:
   - If the file still exists *and* its current `code_hash` matches the
     queue-time `code_hash` — re-source from disk normally; results are
     identical to executing the snapshot.
   - If the file exists but the hash differs — re-source from disk (matching
     the existing relaunch contract) and **emit a `warning()`** naming the
     queued `run_id`, the original hash, and the current hash. The user
     consciously chose to queue an earlier version of the file; tell them they
     got something else.
   - If the file is gone — fall back to the stored `code_body` snapshot, with
     an informational message (matches existing relaunch behavior).
2. **In-place mutation must update `code_body` / `code_hash`** on file-step
   pickup if the file was re-sourced and content differs. Otherwise the
   post-pickup row is internally inconsistent (the `code_hash` says one thing,
   the executed code was another). For inline pickup this is a no-op — the
   captured body never changes.

This keeps file-step semantics consistent with the existing relaunch
contract and never silently hides drift from the user.

### Pickup: in-place mutation

`launch(mr_run(id))` checks the resolved row's `status`:

- **`status = "queued"`** — execute the row's `code_body` (or re-source the
  file for file steps) and **update the row in place**. `run_id`, `step`,
  `rebinds`, `variant_label`, `batch_id` stay frozen. `status` flips to
  `"success"` / `"error"` / `"skipped_fresh"`. `started_at`, `duration_ms`,
  `inputs`, `outputs`, `external_inputs`, `helpers`, and the
  session-context columns (`hostname`, `os`, `arch`, `r_version`, `n_cpu`,
  `total_ram_bytes`, `free_ram_bytes`, etc.) populate. `code_body` and
  `code_hash` stay frozen for inline steps; for file steps they refresh if
  the file was re-sourced and differed (see "Inline vs. file-step capture"
  below).
- **`status` is anything else** (`"success"`, `"error"`, `"skipped_fresh"`,
  `"interactive"`) — behaves exactly as today. A new row is written under the
  resolved `step` + `code_body`; the original row is untouched. This is the
  existing `2026-04-25-launch-by-run-id-design.md` semantics, unchanged.

In-place mutation is **queued-rows-only.** It does not generalize.

### Freshness check at pickup, not at queue

If a queued row would be `skipped_fresh` when `launch()` picks it up — i.e.,
inputs and code have a successful prior run that's still fresh — the in-place
update sets `status = "skipped_fresh"` and skips execution. The queued row
never executes but is recorded as resolved (no orphan `"queued"` row).

Conversely: `queue()` itself never short-circuits. A call like
`queue({ ... })` always inserts a fresh `"queued"` row, even if launching the
same code right now would be `skipped_fresh`. Rationale: staleness can change
between queue time and launch time (inputs may rev), so the freshness decision
belongs at execution, not at staging.

### Batch behavior

`queue({ ... }, rebind = mr_binds(...))` writes N queued rows under one
`batch_id`. Each row independently transitions through pickup. Picking up
queued rows from one batch in arbitrary order is fine — there is no batch-level
state, only per-row status. The "batch" is a join column, not a coordination
primitive.

Batch return: an N-row tibble shaped like `launch()`'s batch return, all rows
`status = "queued"`.

### `runs()` and `is_stale()`

- `runs()` shows queued rows alongside the rest, with `status = "queued"`. No
  filtering changes; queued rows just appear.
- `is_stale()` ignores queued rows (they have no outputs to check staleness
  against). A queued row is neither stale nor fresh — it's pending.

### Concurrent pickup

In v1, two processes calling `launch(mr_run(id))` on the same queued id is
**undefined behavior.** Both will likely execute and the second's in-place
update will overwrite the first's. The queue is single-consumer-per-id by
convention, not by enforcement. Adding row-level locking is a follow-up.

A user driving parallelism via `furrr::future_map(qs$run_id, ~ launch(mr_run(.x)))`
is safe by construction — each id is dispatched to at most one worker.

### Nesting

Calling `queue()` inside a `launch()` body is undefined behavior in v1. The
spec does not attempt to handle it. If the inner `queue()` writes a row,
`launch()` won't see or pick it up; if `launch()` errors out, the inner queued
row remains in the table as orphan-ish. Document "don't" and revisit if a real
workflow surfaces.

## Schema

`_mr_runs` gains **no new columns.** `"queued"` is a new value of the existing
`status` column — there is no schema migration. Existing DuckDB stores in the
wild remain readable; framework invariant 4 (append-only schema migrations) is
not engaged because no DDL runs. Code that branches on status values needs an
audit (`grep -n 'status *== *"' R/` and any `switch(status, ...)`) so the new
value is handled wherever the existing values are, but no on-disk format change
ships.

## Out of scope (v1)

- **No `queue_sql()`.** `launch_sql()` exists as a separate dispatch path, and
  staging a SQL run has its own provenance considerations (the SQL string is
  the artifact). Add when asked.
- **No re-queueing.** `queue(mr_run(id))` errors. Re-queueing a stored run is
  conceptually incoherent — the row already exists.
- **No worker, no daemon, no `drain_queue()`.** `launch()` drains one id per
  call. Users compose via `purrr::walk`, `future`/`furrr`, shell loops, `tsp`,
  HPC submit scripts.
- **No external scheduler integration.** Container-level queueing
  (`tsp`/`pueue`/`nq`/systemd) is a separate concern outside this package.
- **No queue management surface.** No `unqueue()`, no `requeue()`, no
  `queue_status()`. Cleanup goes through `prune()` or direct SQL.
- **No queue-time freshness short-circuit.** `queue()` always inserts.
- **No row-level locking for concurrent pickup.** Convention: one consumer per
  id. Document the constraint, revisit if real workflows hit it.

## Follow-ups (post-v1, not in this spec)

- **Pruning queued rows.** Eventually `prune()` may want a "drop queued rows
  older than X" mode — queued rows that never got launched accumulate
  otherwise. North-star calls out "cleaning out old runs matters."
- **`queue_sql()`.** If the SQL workflow grows a real staging need.
- **Locking for concurrent pickup.** A `SELECT ... FOR UPDATE`-style claim
  step on the row before execution, or a per-id mutex. Defer until needed.
- **Static input pre-resolution at queue time.** Could be a debugging aid
  ("which inputs would this queued run resolve to *right now*?") but isn't
  needed for execution.

## Verification at completion

Before claiming the implementation done (per framework completion criteria):

- `R CMD check` clean.
- `runs()` shows queued rows correctly across single + batch.
- A `queue()` → `launch(mr_run(id))` round-trip produces a row with the same
  `run_id` and the expected post-pickup `status` (`"success"` /
  `"skipped_fresh"`).
- Existing `launch(mr_run(id))` semantics on non-queued rows are unchanged
  (regression test against `2026-04-25-launch-by-run-id-design.md` behavior).
- No code path writes `outputs`, `inputs`, `external_inputs`, `helpers`,
  `started_at`, `duration_ms`, or any session-context column at queue time.
- Vignette section added covering the staging workflow with at least a scalar
  and a batch example. The `final_practicum` package usage is unaffected
  (invariant 1).
