## Effective code hash for a tracked run.
##
## code_hash = md5( script_byte_hash || '\n' || sorted(helper_byte_hashes) )
##
## The sort makes the hash order-stable across runs. Helpers are
## contributed by their byte hash only — paths are not part of the
## hash so that moving a helper within the project doesn't force a
## spurious "code changed" result.

.mr_code_hash <- function(script_path, helpers) {
  script_hash <- .mr_hash_bytes(.mr_read_file_bytes(script_path))
  helper_hashes <- if (length(helpers) > 0L) sort(unlist(helpers, use.names = FALSE)) else character()
  combined <- paste(c(script_hash, helper_hashes), collapse = "\n")
  .mr_hash_bytes(charToRaw(combined))
}
