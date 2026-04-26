#' Load a flat file into the modelrunnR artifact store
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
#' @return A `dbplyr` lazy `tbl` over the ingested table, invisibly.
#'   Users typically don't use the return value directly — they call
#'   [grab()] to read the stored data by name.
#' @export
ingest <- function(name, source) {
  # Body delegated to .mr_stow_file() so the same code path is
  # reachable from the upcoming stow.mr_file dispatch branch (Task 4).
  .mr_stow_file(name, source)
}

# Latest recorded source_hash for a logical name, or NA if none exists.
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
