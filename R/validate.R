## Shared input validators for user-facing entry points.
##
## Logical names flow into three sensitive places:
##   - DuckDB identifiers (escaped via .mr_quote_ident in backend_duckdb.R)
##   - filesystem paths (for large artifacts under modelrunnR_artifacts/)
##   - view names visible to downstream SQL
##
## The DuckDB quoting is safe in isolation, but the filesystem path is
## constructed via file.path(dir, sprintf("%s__%s.qs2", name, hash)), so
## a name like "../../etc/passwd" would escape the artifact directory.
## Validate at the user boundary rather than trying to sanitize after
## the fact at each call site.

.mr_validate_name <- function(name,
                              context = "stow",
                              max_length = 255L) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop(sprintf(
      "%s(): `name` must be a non-empty, non-NA character string.",
      context
    ), call. = FALSE)
  }
  if (nchar(name) > max_length) {
    stop(sprintf(
      "%s(): `name` must be at most %d characters (got %d).",
      context, max_length, nchar(name)
    ), call. = FALSE)
  }
  if (grepl("[/\\\\]|\\.\\.|[[:cntrl:]]", name)) {
    stop(sprintf(
      "%s(): `name` may not contain path separators (/, \\), '..', ",
      context
    ),
    "or control characters. Got: ", sQuote(name),
    call. = FALSE)
  }
  invisible(name)
}
