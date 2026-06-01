#' Mark an inline SQL string for `launch()`
#'
#' Wraps a SQL `SELECT` (or `WITH ... SELECT`) string so [launch()]
#' treats it as a SQL step. Inline equivalent of passing a `.sql` file
#' path to `launch()`.
#'
#' The body must be a single bare query (no `CREATE`, no `INSERT`,
#' exactly one statement). Optional declarative headers go above the
#' body as `--` comment lines:
#'
#' - `-- @inputs: <name>[, <name>...]` — required if the body
#'   references any modelrunnR-managed name.
#' - `-- @output: <name>` — required for inline mode (no filename to
#'   derive an output name from).
#'
#' modelrunnR owns the `CREATE OR REPLACE VIEW` (or `TABLE`) wrapper
#' around the body; users supply only the query.
#'
#' @param body A length-one character string containing the SQL body
#'   plus any header lines.
#' @return A tagged list with class `c("mr_ref_sql", "mr_ref")` for
#'   `launch()` to dispatch on.
#' @examples
#' \dontrun{
#' # Assume `panel_raw` has already been stowed or ingested.
#' launch(mr_sql("
#'   -- @inputs: panel_raw
#'   -- @output: features
#'   SELECT firm_id, year,
#'          lag(sales) OVER (PARTITION BY firm_id ORDER BY year) AS lag_sales
#'   FROM panel_raw
#' "))
#'
#' grab("features") |> dplyr::collect()
#' }
#' @export
mr_sql <- function(body) {
  if (!is.character(body) || length(body) != 1L) {
    stop("mr_sql(): `body` must be a length-1 character string.", call. = FALSE)
  }
  if (is.na(body)) {
    stop("mr_sql(): `body` must not be NA.", call. = FALSE)
  }
  structure(
    list(kind = "sql", body = body),
    class = c("mr_ref_sql", "mr_ref")
  )
}

## Header / body parser ------------------------------------------------------
##
## Pure, side-effect-free. Accepts a single string, returns a list with
## fields:
##   - inputs: character vector (empty if no @inputs declared)
##   - output: a single name, or NULL if @output not declared
##   - body:   the validated query body with trailing `;` stripped
##
## Errors raised by this function are surfaced from launch() before any
## DuckDB write happens. Detection is lexical -- string literals and
## block comments are not parsed away. Good enough for v0.1; a DuckDB-
## backed validation pass can come later if needed.

#' Parse a SQL string into header fields and validated body
#'
#' @param text A length-1 character string holding optional `--`
#'   header lines followed by the SQL body.
#' @return A list with `inputs` (character vector), `output` (single
#'   name or NULL), and `body` (validated, trailing-`;`-stripped query).
#' @noRd
.mr_parse_sql_header <- function(text) {
  if (!is.character(text) || length(text) != 1L || is.na(text)) {
    stop("internal: .mr_parse_sql_header() expects a length-1 character string.",
         call. = FALSE)
  }

  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]

  inputs <- NULL
  output <- NULL
  body_start <- NA_integer_

  for (i in seq_along(lines)) {
    trimmed <- trimws(lines[[i]])
    if (!nzchar(trimmed)) next            # blank
    if (startsWith(trimmed, "--")) {
      after <- trimws(sub("^--", "", trimmed))
      if (startsWith(after, "@")) {
        parsed <- .mr_parse_sql_header_line(after)
        if (parsed$key == "inputs") {
          if (!is.null(inputs)) {
            stop(
              "launch(): repeating '@inputs:' across lines is not supported.",
              call. = FALSE
            )
          }
          inputs <- parsed$value
        } else if (parsed$key == "output") {
          if (!is.null(output)) {
            stop(
              "launch(): repeating '@output:' across lines is not supported.",
              call. = FALSE
            )
          }
          output <- parsed$value
        } else {
          stop(sprintf(
            "launch(): unrecognized SQL header '@%s'. Supported: @inputs, @output.",
            parsed$key
          ), call. = FALSE)
        }
      }
      next  # plain comment, skip
    }
    body_start <- i
    break
  }

  body <- if (is.na(body_start)) "" else paste(
    lines[body_start:length(lines)], collapse = "\n"
  )
  body <- .mr_validate_sql_body(body)

  list(
    inputs = if (is.null(inputs)) character() else inputs,
    output = output,
    body   = body
  )
}

# Parse one "@key: value" line. Returns list(key = chr, value = ...).
#' Parse one `@key: value` SQL header line
#'
#' @param after The header text with the leading `--` already stripped.
#' @return A list with `key` (string) and `value` (character vector for
#'   `inputs`, single string otherwise).
#' @noRd
.mr_parse_sql_header_line <- function(after) {
  if (!grepl(":", after, fixed = TRUE)) {
    stop(sprintf(
      "launch(): malformed SQL header '%s'; expected '@key: value'.",
      after
    ), call. = FALSE)
  }
  eq <- regexpr(":", after, fixed = TRUE)
  key <- trimws(substr(after, 2L, eq - 1L))  # strip leading '@'
  raw_value <- trimws(substr(after, eq + 1L, nchar(after)))

  if (key == "inputs") {
    if (!nzchar(raw_value)) {
      stop("launch(): malformed SQL header '@inputs:'; value is empty.",
           call. = FALSE)
    }
    parts <- trimws(strsplit(raw_value, ",", fixed = TRUE)[[1]])
    if (any(!nzchar(parts))) {
      stop("launch(): malformed '@inputs:' value (empty name).", call. = FALSE)
    }
    return(list(key = key, value = parts))
  }
  if (key == "output") {
    if (!nzchar(raw_value)) {
      stop("launch(): malformed SQL header '@output:'; value is empty.",
           call. = FALSE)
    }
    if (grepl(",", raw_value, fixed = TRUE)) {
      stop("launch(): '@output:' takes a single name; got multiple.",
           call. = FALSE)
    }
    return(list(key = key, value = raw_value))
  }
  list(key = key, value = raw_value)
}

# Validate the body is a bare SELECT (or WITH ... SELECT) and one statement.
# Returns the body trimmed and with the trailing `;` stripped.
#' Validate a SQL body is a single bare SELECT (or WITH ... SELECT)
#'
#' @param body The raw SQL body string.
#' @return The trimmed body with any trailing `;` stripped; errors if
#'   the body is empty, multi-statement, or not a bare query.
#' @noRd
.mr_validate_sql_body <- function(body) {
  trimmed <- trimws(body)
  if (!nzchar(trimmed)) {
    stop("launch(): SQL body is empty.", call. = FALSE)
  }
  stripped <- sub(";\\s*$", "", trimmed)
  # Strip line comments (`-- ...`) AND block comments (`/* ... */`)
  # before paren / multi-statement scans. The block-comment strip is
  # load-bearing -- without it, a body like
  # `SELECT 1 /* ; DROP TABLE x; */` would slip past the
  # multi-statement guard and reach the CREATE wrapper.
  cleaned <- gsub("--[^\n]*", "", stripped)
  cleaned <- gsub("/\\*.*?\\*/", " ", cleaned, perl = TRUE)

  if (grepl(";", cleaned, fixed = TRUE)) {
    stop(
      "launch(): .sql must contain exactly one statement; ",
      "multi-statement SQL is not supported in this spec.",
      call. = FALSE
    )
  }

  first_kw <- toupper(.mr_first_sql_keyword(cleaned))
  if (first_kw == "SELECT") return(stripped)
  if (first_kw == "WITH") {
    terminal <- .mr_with_terminal_keyword(cleaned)
    if (is.null(terminal) || toupper(terminal) != "SELECT") {
      stop(.mr_bare_select_msg(), call. = FALSE)
    }
    return(stripped)
  }
  stop(.mr_bare_select_msg(), call. = FALSE)
}

#' Build the standard "must be a bare SELECT" error message
#'
#' @return A single string explaining the bare-SELECT requirement.
#' @noRd
.mr_bare_select_msg <- function() {
  paste0(
    "launch(): .sql must contain a bare SELECT (or WITH ... SELECT); ",
    "modelrunnR owns the CREATE wrapper. Strip the CREATE/INSERT/etc. ",
    "and leave just the query body."
  )
}

#' Extract the leading alphabetic keyword from a SQL string
#'
#' @param text The SQL text to scan.
#' @return The leading run of letters/underscores, or `""` if none.
#' @noRd
.mr_first_sql_keyword <- function(text) {
  cleaned <- trimws(text)
  m <- regmatches(cleaned, regexpr("^[A-Za-z_]+", cleaned))
  if (length(m) == 0L) "" else m
}

# For a WITH-prefixed body: walk the WITH ... CTE list, then return the
# next top-level keyword. Earlier draft tracked the LAST closing paren
# in the whole body, which mistakenly identified subqueries in the
# terminal SELECT's FROM clause as part of the CTE list and rejected
# valid bodies like `WITH a AS (...) SELECT * FROM (SELECT 1) sub`.
#
# CTE syntax: WITH <ident> AS ( <body> ) [, <ident> AS ( <body> )]* <terminal>
# WITH RECURSIVE is not handled in v0.1; falls through and returns NULL.
#' Find the top-level keyword following a WITH clause's CTE list
#'
#' @param text A WITH-prefixed SQL string.
#' @return The terminal statement keyword (e.g. `"SELECT"`), or NULL if
#'   the CTE list can't be walked to a terminal keyword.
#' @noRd
.mr_with_terminal_keyword <- function(text) {
  chars <- strsplit(text, "", fixed = TRUE)[[1]]
  n <- length(chars)
  i <- 1L

  # Skip leading whitespace, then the WITH word.
  while (i <= n && grepl("[[:space:]]", chars[i])) i <- i + 1L
  while (i <= n && grepl("[A-Za-z]", chars[i])) i <- i + 1L

  repeat {
    while (i <= n && grepl("[[:space:]]", chars[i])) i <- i + 1L
    if (i > n) return(NULL)
    # CTE name (identifier).
    while (i <= n && grepl("[A-Za-z_0-9]", chars[i])) i <- i + 1L
    while (i <= n && grepl("[[:space:]]", chars[i])) i <- i + 1L
    # Expect AS.
    if (i + 1L > n) return(NULL)
    if (toupper(chars[i]) != "A" || toupper(chars[i + 1L]) != "S") return(NULL)
    i <- i + 2L
    while (i <= n && grepl("[[:space:]]", chars[i])) i <- i + 1L
    # Expect '(' opening the CTE body, then walk to matching ')'.
    if (i > n || chars[i] != "(") return(NULL)
    i <- i + 1L
    depth <- 1L
    while (i <= n && depth > 0L) {
      ch <- chars[i]
      if (ch == "(") depth <- depth + 1L
      else if (ch == ")") depth <- depth - 1L
      i <- i + 1L
    }
    if (depth != 0L) return(NULL)
    # After the CTE body. A comma means another CTE follows; anything
    # else (including end-of-string) means the terminal statement begins.
    while (i <= n && grepl("[[:space:]]", chars[i])) i <- i + 1L
    if (i > n) return(NULL)
    if (chars[i] == ",") {
      i <- i + 1L
      next
    }
    break
  }
  if (!grepl("[A-Za-z_]", chars[i])) return(NULL)
  j <- i
  while (j <= n && grepl("[A-Za-z_0-9]", chars[j])) j <- j + 1L
  paste(chars[i:(j - 1L)], collapse = "")
}
