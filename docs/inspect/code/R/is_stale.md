---
source: R/is_stale.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/is_stale.R

## `is_stale(ref)`
_line 28_

Check whether a labeled pipeline's most recent run is stale

Exposes modelrunnR's internal staleness check so users can gate their
own logic on whether a re-run would be a no-op:

```r
if (is_stale(mr_label("embed"))) {
  launch({ ... }, label = "embed")
}
```

For most workflows this is unnecessary — `launch()` skips fresh runs
automatically (see the `force` argument and the
`modelrunnR.skip_if_fresh` option). `is_stale()` is the explicit
escape hatch for the case where the user wants to branch on
staleness without entering `launch()` at all.

@param ref A `mr_label()` or `mr_variant()` reference. Other
  reference constructors (`mr_hash`, `mr_run`, `mr_as_of`) address
  stored content at a point in time; they don't map to the
  "pipeline identity" staleness is about and error here.
@return A logical scalar (`TRUE` if stale, `FALSE` if fresh) with
  a `reasons` attribute carrying the same reason codes that
  `launch()`'s advisory message prints (e.g., `"never_run"`,
  `"code"`, `"input:<name>"`, `"external:<path>"`,
  `"external:env:<NAME>"`).
@export
