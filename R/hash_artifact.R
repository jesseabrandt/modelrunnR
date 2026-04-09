## Artifact byte hashing.
##
## Artifacts are hashed over their serialized raw bytes. We use
## `digest::digest(..., serialize = FALSE)` so the hash is stable
## across R sessions and doesn't depend on R's own serializer
## re-wrapping the input.

.mr_hash_bytes <- function(bytes) {
  stopifnot(is.raw(bytes))
  digest::digest(bytes, algo = "md5", serialize = FALSE)
}
