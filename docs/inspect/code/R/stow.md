---
source: R/stow.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/stow.R

## `stow(value, name)`
_line 57_

Persist a value to the modelrunnR artifact store

Stores `value` under the logical name `name`. Dispatches on type.
The two storage paths are:

- **Append table** (for data frames and lazy DuckDB tbls) — writes
  into a single growing physical table per `name`, stamping every
  row with `_mr_run_id` and `_mr_variant_label`. Running 20 models
  that each `stow(<metrics>, "metrics")` produces one 20-row table,
  not 20 disjoint versions. Schema drift across runs reconciles
  losslessly: new columns are added, missing columns are NULL-filled,
  type conflicts coerce to TEXT (never drops a row).
- **Versioned artifact** (for any other R object) — serialized via
  `qs2`, hashed, and placed in `_mr_artifacts` as a BLOB row when
  serialized size is below `getOption("modelrunnR.blob_threshold")`
  (default 10 MB) or written to
  `<db_dir>/modelrunnR_artifacts/<name>__<hash>.qs2` otherwise. One
  version per distinct value; all previous versions stay queryable
  via [grab()] selectors.

A logical name is tied to one shape on first write. Changing shape
later (e.g. `stow(df, "x")` then `stow(model, "x")`) errors.

Inside a tracked [launch()], each write is recorded on the run row:
for append-table writes, as an `append_table` entry keyed by
`chunk_hash` (the hash of the rows this run contributed); for
artifacts, as a `{name, hash}` pair.

Calling `stow()` outside any `launch()` is supported: it mints an
`<interactive:TS>` synthetic run row (matching the [ingest()]
convention) and stamps the written rows / metadata with that run_id.
Downstream launches that [grab()] an interactively-stowed value
receive the same reproducibility warning that applies to artifact
/ ingest inputs.

Note on serialization: `qs` is no longer maintained for recent R
versions, so modelrunnR uses its successor `qs2` (same fast/compact
format).

@section Hashing contract:
For versioned artifacts, the hash is the serialized-bytes digest.
For append tables, the per-call `chunk_hash` is computed over the
rows this call contributed (order-independent for the eager frame
path; SQL-text-level for the lazy-tbl path — the two hash bases
differ, so round-tripping an identical frame through lazy vs eager
writes will show distinct chunks in [versions()]). Hashing for
DuckDB tables is type-sensitive: integer vs. double columns holding
the same values produce different hashes. Row names are not
persisted.

@param value Any R value. First, so `df |> stow("name")` works.
@param name A length-one character vector. Logical name for the
  value.

@return `value`, invisibly.
@export

## `.mr_stow_table(name, value)`
_line 98_

## `.mr_stow_artifact(name, value)`
_line 159_

## `.mr_maybe_warn_version_count(con, name)`
_line 232_

## `.mr_physical_name(name, hash)`
_line 248_

## `.mr_artifact_file_path(name, hash)`
_line 252_

## `.mr_get_version_row(con, name, hash)`
_line 258_

## `.mr_refresh_latest_view(con, name)`
_line 266_
