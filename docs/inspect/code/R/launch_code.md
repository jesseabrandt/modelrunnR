---
source: R/launch_code.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/launch_code.R

## `launch_code(run_id, from_db = FALSE)`
_line 27_

Retrieve the code body for a previously-launched run

Returns the code that produced `run_id`.

For inline runs (`launch({ ... })`), the code body was deparsed and
stored on the run row at launch time, so there is only one source
to read from.

For script runs (`launch("fit.R")`), there are two possible
sources: the script file as it currently sits on disk, and the
snapshot of the file bytes recorded on the run row at launch time.
By default, `launch_code()` reads the file on disk -- the current
file *is* the pipeline -- and falls back to the stored snapshot
(with a message) when the file has been removed. Pass
`from_db = TRUE` to force reading the stored snapshot even when
the file is still present: useful for auditing what a historical
run actually executed, independent of any later edits.

@param run_id A run id as returned (invisibly) by [launch()] or as
  found on a `_mr_runs` row.
@param from_db If `TRUE`, return the code body stored on the run
  row at launch time, even for script-mode runs whose source file
  is still on disk. Defaults to `FALSE`.

@return A length-one character vector containing the R code.
@export
