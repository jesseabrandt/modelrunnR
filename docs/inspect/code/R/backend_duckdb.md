---
source: R/backend_duckdb.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/backend_duckdb.R

## `.mr_connect(path)`
_line 7_

## `.mr_disconnect(con)`
_line 14_

## `.mr_execute(con, sql, params = NULL)`
_line 21_

## `.mr_table_exists(con, name)`
_line 29_

## `.mr_list_tables(con)`
_line 33_

## `.mr_table_write(con, name, value, overwrite = TRUE)`
_line 37_

## `.mr_has_nondefault_rownames(df)`
_line 44_

## `.mr_table_read(con, name)`
_line 52_

## `.mr_drop_table(con, name)`
_line 56_

## `.mr_quote_ident(name)`
_line 60_

## `.mr_read_file(con, path)`
_line 71_

## `.mr_ingest_file_to_table(con, path, dest_table)`
_line 107_

## `.mr_hash_duckdb_table(con, table_name)`
_line 153_

## `.mr_hash_frame(con, df)`
_line 189_
