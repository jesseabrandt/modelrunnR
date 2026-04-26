---
source: R/prune_variants.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/prune_variants.R

## `prune_variants(script, label, dry_run = FALSE)`
_line 20_

Delete a labeled variant

Removes all `_mr_runs` rows for `script` whose `variant_label`
matches `label`. Versions the deleted runs produced fall back
under the normal "referenced by recent runs" protection — if a
downstream plain run consumed one of them, it stays; otherwise,
the next `prune()` call is free to collect it.

Downstream labeled variants are left alone. Tearing down a whole
labeled pipeline requires calling `prune_variants()` at each
level.

@param script Path to the script whose variant should be removed.
@param label The variant label to delete.
@param dry_run If `TRUE`, print the summary without deleting.
@return Invisibly, a list with fields `script` (normalized path),
  `label`, `n_runs` (rows deleted), and `run_ids` (character vector
  of deleted run IDs).
@export
