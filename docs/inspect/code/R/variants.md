---
source: R/variants.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/variants.R

## `variants(script = NULL, name = NULL)`
_line 14_

List labeled variants

Returns a data frame of labeled variants known to the active
modelrunnR database.

@param script Optional script path (absolute or relative — the
  function normalizes). If supplied, only variants of that script
  are returned.
@param name Optional logical name. If supplied, only variants
  whose runs produced an output under that name are returned.
@return A data frame with columns `script`, `label`, `first_seen`,
  `last_seen`, `n_runs`, `latest_run_id`.
@export

## `.mr_variants_produced(con, df, name)`
_line 43_
