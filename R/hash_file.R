## File content hashing.
##
## Uses base R's `tools::md5sum()` so we don't add a new dependency
## just for hashing flat files. Returns a lower-case hex string or
## stops on missing files.

.mr_file_hash <- function(path) {
  if (!file.exists(path)) {
    stop(sprintf(".mr_file_hash(): file not found: %s", path), call. = FALSE)
  }
  unname(tools::md5sum(path))
}
