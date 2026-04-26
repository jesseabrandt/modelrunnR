#' Tag a file path as a modelrunnR file source
#'
#' Wraps a path in a class (`mr_file`) that [stow()] dispatches on, so
#' a file source flows through the same `stow()` verb as any other
#' value. Validation is lazy — the file does not need to exist at
#' construction time; existence is checked when the value is handed to
#' `stow()`.
#'
#' @param path Length-1 non-empty character: a path to a `.csv`,
#'   `.tsv`, or `.parquet` file.
#'
#' @return A length-1 character vector of class
#'   `c("mr_file", "character")`.
#'
#' @examples
#' \dontrun{
#' stow(mr_file("data/training.parquet"), "training")
#' }
#' @export
mr_file <- function(path) {
  if (!is.character(path) || length(path) != 1L ||
      is.na(path) || !nzchar(path)) {
    stop("mr_file(): `path` must be a length-1 non-empty character.",
         call. = FALSE)
  }
  structure(path, class = c("mr_file", "character"))
}
