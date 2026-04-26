---
source: R/mr_con.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/mr_con.R

## `mr_con()`
_line 19_

Return the DuckDB connection modelrunnR is using

Exposes the package's persistent DuckDB handle so callers can drop
to raw SQL for workflows `dbplyr` doesn't express cleanly — custom
sampling schemes, manual table inspection, etc.

The returned connection is the same one [grab()] and [stow()] use
internally. Do not call `DBI::dbDisconnect()` on it; `modelrunnR`
manages its lifecycle.

@return A `DBIConnection` (specifically, a `duckdb_connection`).
@export

@examples
\dontrun{
con <- mr_con()
DBI::dbGetQuery(con, "SELECT COUNT(*) FROM my_table")
}
