---
source: R/variants_unexplored.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/variants_unexplored.R

## `variants_unexplored(script)`
_line 12_

Labeled upstream variants not yet consumed by a script

For each `grab()` the script has historically made, returns the
set of labeled upstream variants that have produced that name and
a flag indicating whether any run of this script has consumed
that specific upstream hash.

@param script Path to the consumer script.
@return A data frame with columns `logical_name`, `upstream_label`,
  `upstream_hash`, `last_seen`, `used_by_this_script`.
@export
