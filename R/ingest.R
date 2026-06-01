#' Load a flat file into the modelrunnR artifact store
#'
#' @description
#' **Deprecated.** Use `stow(mr_file(source), name)` instead. Kept as
#' a runtime shim that delegates to `stow()`; will be removed after
#' one release cycle.
#'
#' Loads a CSV or Parquet file directly into DuckDB using DuckDB's
#' native `read_csv_auto()` / `read_parquet()` — the file bytes never
#' pass through R memory. The resulting table is stored under `name`,
#' recording the source file's URI and content hash in
#' `_mr_versions` so later [grab()] calls with `source = path` can
#' detect changes and re-ingest when needed.
#'
#' `ingest()` routes through the same storage path as [stow()], so
#' dedup, versioning, and view refresh all behave identically.
#'
#' @section Hashing contract:
#' Column types inferred by DuckDB's `read_csv_auto()` may differ from
#' the types of a frame you might `stow()` directly. Because the
#' content hash is type-sensitive (see [stow()]'s hashing contract), a
#' CSV round-trip through `ingest()` can produce a new version even
#' when the values are numerically identical.
#'
#' @param name Logical name to store the loaded table under.
#' @param source Path to a `.csv`, `.tsv`, or `.parquet` file.
#'
#' @return The `mr_file` object, invisibly (same as `stow(mr_file(source), name)`).
#'   Users typically don't use the return value directly — they call
#'   [grab()] to read the stored data by name.
#' @export
ingest <- function(name, source) {
  .Deprecated(
    msg = paste0(
      "ingest() is deprecated; use `stow(mr_file(source), name)` ",
      "instead. ingest() will continue to work for one release cycle."
    )
  )
  stow(mr_file(source), name)
}

# Latest recorded source_hash for a logical name, or NA if none exists.
#' Look up the latest recorded source hash for a logical name
#'
#' @param con An open DBI connection.
#' @param name The logical name to look up.
#' @return The most recent non-null `source_hash`, or NA if none.
#' @noRd
.mr_latest_source_hash <- function(con, name) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT source_hash FROM _mr_versions
       WHERE logical_name = ? AND source_hash IS NOT NULL
       ORDER BY first_seen DESC
       LIMIT 1",
    params = list(name)
  )
  if (nrow(row) == 0L) NA_character_ else row$source_hash[1]
}
