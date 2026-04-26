#' Internal: attach mr_code class to a character vector
#'
#' Wraps a character vector so that `pull(code_body)` from `runs()` prints
#' as multi-line, syntax-highlighted code rather than a truncated string.
#' The class is purely R-side; the DuckDB column stays plain `TEXT`.
#'
#' @param x A character vector (typically `code_body` straight from
#'   `_mr_runs`). NA elements are preserved.
#' @return The same vector with `"mr_code"` prepended to its class.
#' @keywords internal
#' @noRd
.mr_as_code <- function(x) {
  x <- as.character(x)
  class(x) <- c("mr_code", class(x))
  x
}

#' Print, format, subset, and coerce mr_code vectors
#'
#' `mr_code` is a thin character subclass attached to the `code_body`
#' column of [runs()]. It exists so that pulling the column out of the
#' tibble prints as readable, optionally syntax-highlighted code.
#'
#' @param x An `mr_code` vector.
#' @param i Index passed to `[`.
#' @param ... Unused; present for S3 method signature consistency.
#'
#' @details
#' - `print.mr_code()` writes each element as multi-line code, separating
#'   adjacent elements with a blank line. Syntax highlighting is delegated
#'   to [prettycode::highlight()], which emits ANSI escapes only when
#'   `crayon::has_color()` is `TRUE` — Rscript at a color-capable terminal
#'   gets highlighting; pipes, files, and knitr get plain text.
#' - `format.mr_code()` returns short summaries like `"<412 chr>"` so the
#'   tibble print layout stays compact.
#' - `as.character.mr_code()` strips the class and returns the underlying
#'   strings; standard string ops (`paste`, `gsub`, `nchar`, `writeLines`)
#'   coerce through it transparently.
#' - `[.mr_code` preserves the class on subsetting so
#'   `head(pull(code_body), 1)` still prints as code.
#'
#' @name mr_code
NULL

#' @rdname mr_code
#' @export
format.mr_code <- function(x, ...) {
  raw <- unclass(x)
  ifelse(is.na(raw),
         NA_character_,
         paste0("<", nchar(raw), " chr>"))
}

#' @rdname mr_code
#' @export
as.character.mr_code <- function(x, ...) {
  unclass(x)
}

#' @rdname mr_code
#' @export
`[.mr_code` <- function(x, i) {
  out <- unclass(x)[i]
  class(out) <- c("mr_code", class(out))
  out
}
