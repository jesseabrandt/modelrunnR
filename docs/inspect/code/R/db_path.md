---
source: R/db_path.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/db_path.R

## `db_path()`
_line 16_

Get the active DuckDB file path

Returns the path modelrunnR will use (or is using) for its DuckDB
artifact store. Path resolution:

1. `getOption("modelrunnR.db")` if set.
2. Otherwise, walk up from `getwd()` looking for a project marker
   (`DESCRIPTION`, `*.Rproj`, `.git/`, `renv.lock`, `.here`). If a
   root is found, the default path is `<root>/modelrunnR.duckdb`.
3. If no marker is found, the default is
   `<cwd>/modelrunnR.duckdb` **and** a warning suggests adding a
   project marker so the location is stable across subdirectories.

@return A length-one character vector with the resolved DB path.
@export
