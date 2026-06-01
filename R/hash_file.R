## File content hashing.
##
## Uses base R's `tools::md5sum()` so we don't add a new dependency
## just for hashing flat files. Returns a lower-case hex string or
## stops on missing files.

#' Hash a flat file's contents with md5
#'
#' @param path path to the file to hash
#' @return a lower-case hex md5 string; stops on missing file
#' @noRd
.mr_file_hash <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf(".mr_file_hash(): file not found: %s", path), call. = FALSE)
  }
  unname(tools::md5sum(path))
}
