#' Get the active DuckDB file path
#'
#' Returns the path modelrunnR will use (or is using) for its DuckDB
#' artifact store. Path resolution:
#'
#' 1. `getOption("modelrunnR.db")` if set.
#' 2. Otherwise, walk up from `getwd()` looking for a project marker
#'    (`DESCRIPTION`, `*.Rproj`, `.git/`, `renv.lock`, `.here`). If a
#'    root is found, the default path is `<root>/modelrunnR.duckdb`.
#' 3. If no marker is found, the default is
#'    `<cwd>/modelrunnR.duckdb` **and** a warning suggests adding a
#'    project marker so the location is stable across subdirectories.
#'
#' @return A length-one character vector with the resolved DB path.
#' @export
db_path <- function() {
  override <- getOption("modelrunnR.db", default = NULL)
  if (!is.null(override) && nzchar(override)) {
    return(override)
  }

  root <- .mr_project_root(start = getwd())
  if (!is.null(root)) {
    return(file.path(root, "modelrunnR.duckdb"))
  }

  warning(
    "modelrunnR could not find a project marker (DESCRIPTION, .Rproj, .git/, ",
    "renv.lock, .here) walking up from ", getwd(), ". Falling back to ",
    "<cwd>/modelrunnR.duckdb. Add a project marker to keep the DB location ",
    "stable across subdirectories.",
    call. = FALSE
  )
  file.path(getwd(), "modelrunnR.duckdb")
}
