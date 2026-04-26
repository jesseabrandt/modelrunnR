---
source: R/mr_sql.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/mr_sql.R

## `mr_sql(body)`
_line 37_

Mark an inline SQL string for `launch()`

Wraps a SQL `SELECT` (or `WITH ... SELECT`) string so [launch()]
treats it as a SQL step. Inline equivalent of passing a `.sql` file
path to `launch()`.

The body must be a single bare query (no `CREATE`, no `INSERT`,
exactly one statement). Optional declarative headers go above the
body as `--` comment lines:

- `-- @inputs: <name>[, <name>...]` — required if the body
  references any modelrunnR-managed name.
- `-- @output: <name>` — required for inline mode (no filename to
  derive an output name from).

modelrunnR owns the `CREATE OR REPLACE VIEW` (or `TABLE`) wrapper
around the body; users supply only the query.

@param body A length-one character string containing the SQL body
  plus any header lines.
@return A tagged list with class `c("mr_ref_sql", "mr_ref")` for
  `launch()` to dispatch on.
@examples
\dontrun{
# Assume `panel_raw` has already been stowed or ingested.
launch(mr_sql("
  -- @inputs: panel_raw
  -- @output: features
  SELECT firm_id, year,
         lag(sales) OVER (PARTITION BY firm_id ORDER BY year) AS lag_sales
  FROM panel_raw
"))

grab("features") |> dplyr::collect()
}
@export

## `.mr_parse_sql_header(text)`
_line 63_

## `.mr_parse_sql_header_line(after)`
_line 124_

## `.mr_validate_sql_body(body)`
_line 162_

## `.mr_bare_select_msg()`
_line 196_

## `.mr_first_sql_keyword(text)`
_line 204_

## `.mr_with_terminal_keyword(text)`
_line 218_
