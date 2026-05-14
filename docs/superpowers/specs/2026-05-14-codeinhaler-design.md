# codeinhaler — schema and verb design

**Status:** design, drafted 2026-05-14. Consolidates the brainstorming
that took the project from "modelrunnR with a code-snapshot table" to
"a code database accumulator knows how to run code."
The plan is to fork into a new repository `codeinhaler` once this spec
is reviewed; modelrunnR v0.1.0 stays frozen as the run-only artifact.

**Scope:** Schema (DuckDB) and verb shape for the new package. Does *not*
cover: implementation order, test strategy, vignette plan, or the
detailed mechanics of promotion (parked, see Deferred).

**Depends on:** the L0 source-snapshot work in modelrunnR (`_mr_code` /
`_mr_code_helpers` and the parsing/hashing machinery in `R/hash_code.R`,
`R/code_snapshot.R`) — codeinhaler reuses those primitives but restructures
the schema around them.

## The shift

modelrunnR is a *run journal*: the central record is "a launch happened,"
and code is attached as provenance so the run can be reconstructed. The
schema reflects that — `_mr_runs` is the trunk, `_mr_code` hangs off it.

codeinhaler inverts the trunk. Code is the primary stored content; runs
are *one kind of evidence* about a code object (it was used in launch X
with inputs Y). The package is a **maturation pipeline**: code enters as
exhaust, gets named, gets curated to reusable, and gets exported cleanly
to a package or file. Per-project by default, with a personal-level db
that projects can vacuum refined functions up into.

The package metaphor is an inhaler: messy in, clean out.

## Verbs

| Verb | Role |
|---|---|
| `inhale(...)` | Capture code into the db. From a file, an inline block, or auto-fired by `launch()` for the script that ran. Writes an `inhaled`-status row. |
| `promote(code, ...)` | Curate. Attach roxygen, set name if missing, flip status to `promoted`. Writes a new row referencing the parent (pure history, no mutation). |
| `export(code, format = "package", to = path)` | Emit out cleanly. Target is a code object *or* a group; format is `package`, `file`, or future kinds. The first argument is named `code` (the thing being exported), not `target` (which reads as destination). |
| `vacuum(from, to, where = ...)` | Copy code rows from one db to another. Same primitive in both directions (project ↔ personal). License-aware. |
| `launch(...)`, `queue(...)`, `grab(...)`, `stow(...)` | Carried over from modelrunnR; "how code gets used." `launch()` auto-fires `inhale()` for its script. |

`inhale / promote / export` is the messy-in / clean-out arc.

## Schema

Each project gets its own DuckDB file; the file *is* the namespace, so
no `_mr_` / `inh_` prefix on table names. The same schema applies to
the personal db.

### Tables

```
blob
  blob_hash      TEXT PRIMARY KEY
  bytes          BLOB
  size_bytes     BIGINT
  recorded_at    TIMESTAMP

code
  code_id                TEXT PRIMARY KEY        -- uuid
  name                   TEXT                    -- nullable for raw exhaust
  kind                   TEXT                    -- function | script | snippet | sql
  status                 TEXT                    -- inhaled | named | promoted
  content_hash           TEXT → blob.blob_hash
  language               TEXT                    -- r | sql | python | ...
  signature_json         TEXT                    -- parsed function signature
  roxygen_json           TEXT                    -- parsed @param/@return/@export/@examples
  license                TEXT                    -- "MIT" | "CC-BY-SA" | "unknown" | ...
  origin_db              TEXT                    -- NULL for native; identifier of source db
  origin_code_id         TEXT                    -- NULL for native; original code_id in source
  promoted_from_code_id  TEXT                    -- self-ref for the promote act
  created_at             TIMESTAMP

group
  group_id       TEXT PRIMARY KEY
  name           TEXT UNIQUE
  description    TEXT
  created_at     TIMESTAMP

group_member
  group_id       TEXT
  code_id        TEXT

code_tag
  code_id        TEXT
  tag            TEXT

edge
  src_id         TEXT
  dst_id         TEXT
  kind           TEXT                            -- calls | derived_from | replaces
  created_at     TIMESTAMP

env
  code_id        TEXT
  pkg            TEXT
  version        TEXT
  source         TEXT                            -- CRAN | github | local | ...

export
  export_id      TEXT PRIMARY KEY
  code_id        TEXT                            -- mutually exclusive with group_id
  group_id       TEXT
  format         TEXT                            -- package | file | ...
  to_path        TEXT
  manifest_json  TEXT
  exported_at    TIMESTAMP

runs
  -- absorbed from _mr_runs, prefix dropped. The old `code_hash` column
  -- becomes `code_id` (FK into code); content addressing is preserved
  -- one hop deeper via code.content_hash → blob.blob_hash.
  -- Variants / batches / external_inputs / git/session columns all
  -- carry over unchanged.
```

### Why two layers (blob + code)

Identity and naming are separate concerns. `blob` is the
content-addressed object store (dedup, integrity, "did this change").
`code` is the named/typed/curated view *over* the blobs (lookup,
versions, groups, promotion status). Git models the same split:
objects vs. refs.

A `name` is not unique in `code` — multiple rows = the version timeline
for that name. "Latest `plot_residuals`" = most recent `created_at`
under that name with `status = 'promoted'` (Q5: pure history, no
mutable refs).

### Why groups are first-class, not just tags

`export(code, ...)` accepts a code object *or a group*. A group is the
unit of "this set of functions belongs together and ships together,"
so it earns a row + membership table. Free-form `code_tag` stays too
for ad-hoc filtering ("show me everything tagged `experimental`") that
doesn't justify a named group.

### License lives on code, not blob

Two code rows over the same bytes could legitimately carry different
licenses (e.g., user inhaled the same function into two projects with
different LICENSE files). Blob is bytes-only; license is curation
metadata.

## Cross-db model

```
project_a/inhaler.duckdb ──┐
project_b/inhaler.duckdb ──┼──vacuum──> ~/.inhaler/personal.duckdb
project_c/inhaler.duckdb ──┘                       │
                                                  pull
                                                   ▼
                                          project_d/inhaler.duckdb
```

- **Project db**: lives at the project root (path TBD — likely
  `./inhaler.duckdb` or `./.inhaler/db.duckdb`).
- **Personal db**: location resolved as (1) env var `INHALER_PERSONAL_DB`
  if set, else (2) `~/.inhaler/personal.duckdb`. Same schema as any
  project db.
- **Vacuum** is db-to-db with filters. Copies bytes (Q15) — the
  destination db is self-contained. Provenance preserved via
  `origin_db` + `origin_code_id` so a re-vacuum can detect already-pulled
  rows and avoid duplicates.

The verb is symmetric: `vacuum(from, to, where)`. "Project → personal"
and "personal → project" are the same operation with the paths swapped.

### License handling at vacuum time

- Project default license is auto-detected from the project root's
  LICENSE file at inhale time (Q14). Per-`inhale()` override accepted.
- Vacuum **warns** on rows with `license = 'unknown'`.
- Vacuum **refuses** on rows with non-permissive licenses unless the
  caller passes `force = TRUE`. Permissive allowlist: MIT, Apache-2.0,
  BSD-2/3, CC0, ISC, Unlicense, public domain. Anything outside that
  list trips the refuse.

## Settled decisions (Q1–Q15)

For traceability against the brainstorming session that produced this:

| # | Question | Answer |
|---|---|---|
| 1 | Atomic unit of stored code | Function-with-roxygen is canonical; scripts/snippets supported via `kind`. |
| 2 | Can code exist without a run | Yes. The accumulator is independent of launches. |
| 3 | Identity: hash vs name vs both | Two layers: content-addressed `blob` + named/curated `code`. |
| 4 | Lineage when scripts become functions | Edge: `edge(src, dst, kind = "derived_from")`. |
| 5 | Mutable refs vs pure history | Pure history. "Latest" = most-recent row by `created_at`. |
| 6 | User-facing record API | File primary (`inhale("R/plot.R")`), inline secondary (`inhale({...})`), live-object convenience (`inhale(my_fn)`) drops roxygen. |
| 7 | Roxygen storage | Structured `roxygen_json` extracted at inhale time. `roxygen2` becomes a hard dep (invariant-3 ASK answered: yes). |
| 8 | Pivot vs append | New repo. modelrunnR v0.1.0 frozen. |
| 9 | Promotion granularity | Single `promoted` status for v0.1; levels deferred. |
| 10 | Export API shape | `export(code, format, to)`. First arg is `code` (the thing exported), not `target`. |
| 11 | Keep modelrunnR machinery | Absorb everything. `launch`/`queue`/`grab`/`stow` carry over. |
| 12 | Package name | `codeinhaler` (verify CRAN availability before locking). |
| 13 | Personal db location | Env var `INHALER_PERSONAL_DB`, fallback `~/.inhaler/personal.duckdb`. |
| 14 | License source | Project LICENSE auto-detect + project default + per-call override. |
| 15 | Vacuum: copy or reference | Copy bytes. Self-contained destination; `origin_db` preserves trail. |

## Deferred

- **Promotion mechanics.** Exact rules for `inhaled → named → promoted`
  transitions are TBD ("idk yet"). We'll learn the right shape from
  using it. Promotion-as-levels (Q9b) is still on the table for later.
- **Runs absorption details.** Most of `_mr_runs` carries over with the
  `code_hash → code_id` swap, but specific columns (batch_id,
  external_inputs, rebinds, variant_label, the session/git telemetry)
  may reshape once "runs as evidence" is built out. Don't pre-design;
  port as-is and refactor when it pinches.
- **Variants / batches / sweeps.** modelrunnR's `mr_binds()` /
  `mr_envelopes()` machinery is intentionally out of scope until
  `inhale / promote / export` is working end-to-end. Likely carries
  over but may be reshaped under "code is primary."
- **Additional export formats.** v0.1 ships `format = "package"` (full
  R package, walks `edge.kind = "calls"`, respects `@export`) and
  `format = "file"` (single `.R` with promoted code + roxygen). Gist,
  clipboard, others later.
- **Auto-call-graph extraction.** Populating `edge(kind = "calls")`
  requires walking parsed code for function references. Useful for
  export dependency closure; not v0.1 unless cheap.
- **Multi-language inhale.** R-only for v0.1; SQL piggybacks on
  modelrunnR's existing path. Python via reticulate, etc., deferred.

## Fork plan

1. **Now:** spec lives on the `code-inhaler` branch of modelrunnR. No
   schema code written yet; design lives in this file.
2. **Review pass:** edit this spec in place. Lock the `code` arg name,
   re-check Q12 (CRAN availability for `codeinhaler`), tighten anything
   that reads off.
3. **Fork:** create new repo `codeinhaler`. Copy this spec across as
   the founding design doc. Bootstrap with `usethis::create_package()`,
   `use_mit_license()`, `use_testthat(3)`, `use_roxygen_md()`. Add
   `DuckDB`, `roxygen2`, `digest` to Imports.
4. **modelrunnR v0.1.0 stays frozen.** Existing DuckDB stores in the
   wild are read-only artifacts; codeinhaler does not migrate them
   (no `_mr_*` ↔ codeinhaler schema bridge). Anyone iterating actively
   moves to codeinhaler from scratch.

## Cross-references

- `north_star.md` — the "Code Database Accumulator" vision and the
  "scripts become functions" line in §1.
- `framework.md` — invariants this design supersedes (the new repo
  starts clean; invariant 2's append-only constraint is not inherited
  because the schema is new, not migrated).
- `docs/superpowers/specs/2026-05-13-code-snapshot-design.md` — the L0
  spec whose `_mr_code` / `_mr_code_helpers` work feeds the new `blob`
  table. The reproducibility roadmap (L0 → L1 → L2 → L3) survives the
  morph: L1 (env lockfile) maps onto the `env` table; L3 (export)
  maps onto the `export` table + the `export()` verb.
- `R/hash_code.R`, `R/code_snapshot.R` — primitives that port forward.
