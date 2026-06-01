## Artifact byte hashing.
##
## Artifacts are hashed over their serialized raw bytes. We use
## `digest::digest(..., serialize = FALSE)` so the hash is stable
## across R sessions and doesn't depend on R's own serializer
## re-wrapping the input.

#' Hash raw bytes with md5
#'
#' @param bytes a raw vector to hash
#' @return a lower-case hex md5 string
#' @noRd
.mr_hash_bytes <- function(bytes) {
  stopifnot(is.raw(bytes))
  digest::digest(bytes, algo = "md5", serialize = FALSE)
}
