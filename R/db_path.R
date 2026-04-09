#' Get the active DuckDB file path
#'
#' Returns the path modelrunnR will use (or is using) for its DuckDB
#' artifact store. Path resolution in v0.1 is:
#'
#' 1. `getOption("modelrunnR.db")` if set.
#' 2. Otherwise, `file.path(getwd(), "modelrunnR.duckdb")`.
#'
#' Slice 2 adds a project-root walker; until then the default is cwd-based.
#'
#' @return A length-one character vector with the resolved DB path.
#' @export
db_path <- function() {
  override <- getOption("modelrunnR.db", default = NULL)
  if (!is.null(override) && nzchar(override)) {
    return(override)
  }
  file.path(getwd(), "modelrunnR.duckdb")
}
