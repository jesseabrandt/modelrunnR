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
##
## Names must match [A-Za-z_][A-Za-z0-9_]* — letters, digits, and
## underscores only, not starting with a digit. The SQL-launch path
## substitutes @inputs names via `\b<name>\b` word-boundary matching;
## `_` is a word character so `\bfeatures\b` doesn't match inside
## `features_extended`. Any non-word character (hyphen, dot, space)
## would invert that: `\bfeatures\b` WOULD match inside `features-v2`
## and silently corrupt the rendered SQL. Keeping names word-only is
## what makes the substitution provably sound.

.mr_name_pattern <- "^[A-Za-z_][A-Za-z0-9_]*$"

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
  if (!grepl(.mr_name_pattern, name)) {
    stop(sprintf(
      "%s(): `name` must contain only letters, digits, and underscores, and not start with a digit. Got: %s",
      context, sQuote(name)
    ), call. = FALSE)
  }
  if (startsWith(name, "_mr_")) {
    stop(sprintf(
      "%s(): names starting with `_mr_` are reserved for modelrunnR's metadata tables (`_mr_runs`, `_mr_versions`, `_mr_append_tables`, ...). Got: %s",
      context, sQuote(name)
    ), call. = FALSE)
  }
  invisible(name)
}

.mr_validate_label <- function(label) {
  if (is.null(label)) return(NA_character_)
  if (!is.character(label) || length(label) != 1L || is.na(label)) {
    stop("launch(): `label` must be a single non-NA string.", call. = FALSE)
  }
  trimmed <- trimws(label)
  if (!nzchar(trimmed)) {
    stop("launch(): `label` must not be empty or whitespace-only.", call. = FALSE)
  }
  trimmed
}
