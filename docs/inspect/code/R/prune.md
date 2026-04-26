---
source: R/prune.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/prune.R

## `prune(name = NULL, by = c("auto", "version", "run", "age")`
_line 34_

Prune stored values

Remove stored data from the modelrunnR store. Works on both storage
shapes:

- **Versioned (Shape A)** — drops entire `(name, content_hash)` rows
  from `_mr_versions` and their physical artifacts.
- **Append (Shape B)** — deletes rows from the growing append table
  by `run_id` / age, keeping the registry row so the accumulator
  still exists under its logical name.

Dispatches on the shape of `name`. Without `name`, applies the
policy to every logical name in the store (both shapes).

@param name Optional logical name to restrict pruning to.
@param by One of `"auto"`, `"version"`, `"run"`, `"age"`. The default
  `"auto"` dispatches on shape. `"version"` requires a Shape A name;
  `"run"` requires a Shape B name; `"age"` is a shape-agnostic
  shortcut that uses only `older_than`.
@param run_id Character vector of run ids to prune (Shape B only).
@param keep Integer; keep the N most recent versions (Shape A) or
  runs (Shape B). Applied per logical name.
@param keep_latest Logical; shorthand for `keep = 1`. Shape A only.
@param older_than Duration string (`"30d"`, `"6h"`, `"15m"`,
  `"45s"`). Works on both shapes.
@param force Logical. If `TRUE`, overrides protection (run-referenced
  versions on Shape A, variant-labeled runs on Shape B).

@return Invisibly. For a single-shape call, a data frame describing
  what was pruned. For calls that span both shapes (`name = NULL`
  with `by = "auto"`, or `by = "age"`), a list with `$versioned` and
  `$append` data frames.
@export

## `.mr_prune_shape_a(name, keep, keep_latest, older_than, force)`
_line 96_

## `.mr_select_prune_candidates(candidates, keep, keep_latest, older_than)`
_line 154_

## `.mr_parse_duration(spec, context = "prune")`
_line 184_

## `.mr_protected_version_hashes(con, force = FALSE)`
_line 196_

## `.mr_drop_version(con, row)`
_line 257_

## `.mr_prune_shape_b(name, run_id, keep, older_than, force)`
_line 299_

## `.mr_prune_shape_b_one(con, registry_row, run_id, cutoff, keep, force)`
_line 327_
