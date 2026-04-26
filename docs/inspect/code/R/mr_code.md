---
source: R/mr_code.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/mr_code.R

## `.mr_as_code(x)`
_line 11_

Internal: attach mr_code class to a character vector

Wraps a character vector so that `pull(code_body)` from `runs()` prints
as multi-line, syntax-highlighted code rather than a truncated string.
The class is purely R-side; the DuckDB column stays plain `TEXT`.

@param x A character vector (typically `code_body` straight from
  `_mr_runs`). NA elements are preserved.
@return The same vector with `"mr_code"` prepended to its class.
@noRd

## `format.mr_code(x, ...)`
_line 46_

@rdname mr_code
@export

## `as.character.mr_code(x, ...)`
_line 55_

@rdname mr_code
@export

## `print.mr_code(x, ...)`
_line 69_

@rdname mr_code
@export
