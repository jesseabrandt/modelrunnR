---
source: R/grab.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/grab.R

## `grab(name, version = NULL, from_run = NULL, as_of = NULL, source = NULL, variant = NULL, run = NULL)`
_line 76_

Retrieve a value from the modelrunnR artifact store

modelrunnR stores tabular values two ways — as **versioned** snapshots
(one row per distinct content) and as **append tables** (one growing
table, row-stamped per run). `grab()` dispatches on which shape `name`
was stored as, so the same call works regardless. The distinction is
explained in the Getting Started vignette.

**Versioned (Shape A)** — data the package treats as immutable: ingested
reference data, non-tabular artifacts (models, lists, results). The
default returns the current latest version; historical versions can be
selected via `version` (content hash), `from_run` (run id), or `as_of`
(timestamp), in that precedence order. Pass `run = "all"` to get a
**named list** of every stored version (one element per content hash,
ordered oldest -> newest).

**Append (Shape B)** — data frames you `stow()` inside runs. The default
returns one coherent snapshot — the rows from a single run — with system
columns (`_mr_run_id`, `_mr_variant_label`) stripped, so `grab(name)`
gives you user columns only. Which run depends on context: inside a
[launch()] block it is the *current* run (rows this run has written so
far); outside a launch it is the *latest* run that wrote to `name`. The
exploratory workflow — `grab("metrics") |> collect()` at the REPL —
thus pulls a clean slice rather than the accumulated cross-run pile.
Pass `run = "all"` to opt into the full-history view: every row, with
system columns surfaced as user-facing `run_id` and `variant_label`
columns — the right lens for comparing runs.

Inside a tracked [launch()], the read is recorded as an input
`{name, hash}` pair on the run row. Outside a launch, the read
is not logged.

When `source` is supplied, `grab()` behaves as an idempotent
read-or-ingest: if `name` does not exist yet, [ingest()] is called
under the hood. If `name` exists and the file's current content
hash differs from the latest stored `source_hash`, `ingest()`
is called again and a new version is created. If the file is
unchanged, the cached version is returned.

@param name A length-one character vector naming a logical value.
@param version Optional content hash (as returned by [versions()])
  to select a specific stored version. Shape A only.
@param from_run Optional run id (as returned by [launch()]'s
  invisibly-returned run row) to select the exact version produced
  by that run. For Shape B tables, filters to rows from that run.
@param as_of Optional `POSIXct` timestamp; returns the version
  that was latest at that time. Shape A only.
@param source Optional path to a CSV or Parquet file. Triggers an
  implicit [ingest()] when the file hash differs from (or is not
  yet present in) the stored source metadata.
@param variant Optional string; resolves to the latest version produced
  by any run launched with `label = variant`. Mutually exclusive with
  `version`, `from_run`, `as_of`, and `run`. See *Variants and
  swappability* in docs/design.md for the full semantics.
@param run Cross-history selector. On Shape B (append tables), a run id
  string filters to that run's rows, or `"all"` returns every row with
  `run_id` and `variant_label` exposed. On Shape A (versioned), only
  `"all"` is accepted and returns a named list of every stored version
  keyed by `content_hash`.

@section Security note:
Artifacts stored via [stow()] are deserialized on read with
`qs2::qs_deserialize()`. Opening a project produced by someone else
trusts the artifacts to the same extent as trusting that party's R
code: `qs2` does not have `readRDS`'s historical callback
arbitrary-code-execution surface, but it has not been independently
audited. Do not `grab()` from projects you would not `source()`.

@return For tabular stored values (ingested files, stowed data
  frames), a `dbplyr` lazy `tbl` bound to the modelrunnR DuckDB
  connection. Compose `dplyr` verbs against it and call
  [dplyr::collect()] (or [as.data.frame()] / [tibble::as_tibble()])
  to materialize. For non-tabular artifacts, the deserialized R
  object.
@export

## `.mr_read_value(con, row)`
_line 190_

## `.mr_maybe_ingest(con, name, source)`
_line 219_

## `.mr_resolve_version(con, name, version, from_run, as_of)`
_line 241_

## `.mr_read_by_hash(con, name, hash)`
_line 334_

## `.mr_grab_by_variant(name, variant)`
_line 347_

## `.mr_latest_hash_for_variant(con, name, variant)`
_line 358_
