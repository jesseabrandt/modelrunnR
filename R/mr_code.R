#' Low-level constructor for the mr_code class
#'
#' Attaches the `"mr_code"` class to a character vector without any
#' coercion. The class is purely R-side; the DuckDB column stays plain
#' `TEXT`. Callers that may be handed a non-character should coerce
#' first or go through `.mr_as_code()`.
#'
#' @param x A character vector (typically `code_body` straight from
#'   `_mr_runs`). NA elements are preserved.
#' @return `x` with `"mr_code"` prepended to its class.
#' @noRd
new_mr_code <- function(x = character()) {
  stopifnot(is.character(x))
  class(x) <- c("mr_code", class(x))
  x
}

#' Validate an mr_code object
#'
#' Confirms the class invariant: an `mr_code` is a character vector
#' carrying the `"mr_code"` class. Returns its input invisibly-by-value
#' so it composes inside a construction expression.
#'
#' @param x An object expected to be `mr_code`.
#' @return `x`, unchanged, if it is a valid `mr_code`; errors otherwise.
#' @noRd
validate_mr_code <- function(x) {
  if (!inherits(x, "mr_code")) {
    stop("`x` must be an <mr_code> object.", call. = FALSE)
  }
  if (!is.character(unclass(x))) {
    stop("`mr_code` must wrap a character vector.", call. = FALSE)
  }
  x
}

#' Internal: attach mr_code class to a character vector
#'
#' Wraps a character vector so that `pull(code_body)` from `runs()` prints
#' as multi-line, syntax-highlighted code rather than a truncated string.
#' The class is purely R-side; the DuckDB column stays plain `TEXT`.
#' Idempotent: an object that is already `mr_code` is returned unchanged.
#' Construction is routed through `new_mr_code()` + `validate_mr_code()`.
#'
#' @param x A character vector (typically `code_body` straight from
#'   `_mr_runs`). NA elements are preserved.
#' @return The same vector with `"mr_code"` prepended to its class.
#' @noRd
.mr_as_code <- function(x) {
  if (inherits(x, "mr_code")) return(x)
  validate_mr_code(new_mr_code(as.character(x)))
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
#'   gets highlighting; pipes and files get plain text.
#' - `knit_print.mr_code()` is registered for the `knitr::knit_print`
#'   generic so that pulling `code_body` in a knitr/Quarto chunk emits a
#'   fenced \verb{```r} block per element. Pandoc/Quarto's syntax
#'   highlighter takes it from there; ANSI escapes from the console
#'   `print` method are bypassed entirely.
#' - `format.mr_code()` returns short summaries like `"<412 chr>"` so the
#'   tibble print layout stays compact.
#' - `as.character.mr_code()` strips the class and returns the underlying
#'   strings; standard string ops (`paste`, `gsub`, `nchar`, `writeLines`)
#'   coerce through it transparently.
#' - `[.mr_code` and `[[.mr_code` preserve the class on subsetting so
#'   `head(pull(code_body), 1)` and `pull(code_body)[[1]]` still print as
#'   code.
#'
#' @return
#' - `print.mr_code()` invisibly returns its input.
#' - `format.mr_code()` returns a plain `character` vector of summaries
#'   (one per element); the class is intentionally not preserved so
#'   tibble can render the cells as plain text.
#' - `as.character.mr_code()` returns a plain `character` vector with
#'   the class stripped.
#' - `[.mr_code` and `[[.mr_code` return an `mr_code` vector.
#' - `knit_print.mr_code()` returns a `knit_asis` object containing
#'   one fenced \verb{```r} block per element (or `<no code body>` for
#'   `NA` / empty elements), separated by blank lines.
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
  new_mr_code(unclass(x)[i])
}

#' @rdname mr_code
#' @export
`[[.mr_code` <- function(x, i) {
  new_mr_code(unclass(x)[[i]])
}

#' @rdname mr_code
#' @exportS3Method knitr::knit_print
knit_print.mr_code <- function(x, ...) {
  raw <- unclass(x)
  parts <- vapply(raw, function(s) {
    if (is.na(s) || !nzchar(s)) {
      "<no code body>"
    } else {
      paste0("```r\n", s, "\n```")
    }
  }, character(1))
  knitr::asis_output(paste0("\n\n", paste(parts, collapse = "\n\n"), "\n\n"))
}

#' @rdname mr_code
#' @export
print.mr_code <- function(x, ...) {
  raw <- unclass(x)
  for (i in seq_along(raw)) {
    if (i > 1) writeLines("")
    s <- raw[[i]]
    if (is.na(s) || !nzchar(s)) {
      writeLines("<no code body>")
    } else {
      # prettycode::highlight() treats each vector element as one source line.
      # Splitting first ensures every line is colored (a single multi-line
      # string would only get the first line highlighted).
      lines <- strsplit(s, "\n", fixed = TRUE)[[1]]
      writeLines(prettycode::highlight(lines))
    }
  }
  invisible(x)
}
