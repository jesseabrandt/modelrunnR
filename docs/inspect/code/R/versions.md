---
source: R/versions.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/versions.R

## `versions(name)`
_line 21_

List stored versions of a logical name

Returns one row per distinct version of `name`, with the metadata
needed to inspect history and decide what to keep versus prune.
`produced_by_runs` is a list-column of the run ids that produced each
version (empty when the version was written outside any tracked run).

Works on both storage shapes. For **versioned** (Shape A) names each
row is one `(logical_name, content_hash)` pair. For **append** (Shape
B) names each row is one appended chunk; `content_hash` is the
chunk's hash and `produced_by_runs` lists the single run that wrote
it. Rows are ordered **latest first** on both shapes.

@param name A length-one character vector naming a logical value.

@return A data frame with columns `content_hash`, `first_seen`,
  `last_seen`, `size_bytes`, `produced_by_runs`, ordered latest
  first. `size_bytes` is `NA` for Shape B rows — the value is tracked
  at the table level in `_mr_append_tables`, not per chunk.
@export
