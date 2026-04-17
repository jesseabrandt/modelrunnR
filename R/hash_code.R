## Effective code hash for a tracked run.
##
## code_hash = md5( script_byte_hash || '\n' || sorted(helper_byte_hashes) )
##
## The sort makes the hash order-stable across runs. Helpers are
## contributed by their byte hash only -- paths are not part of the
## hash so that moving a helper within the project doesn't force a
## spurious "code changed" result.

.mr_code_hash <- function(script_path, helpers) {
  script_hash <- .mr_hash_bytes(.mr_read_code_bytes(script_path))
  helper_hashes <- if (length(helpers) > 0L) sort(unlist(helpers, use.names = FALSE)) else character()
  combined <- paste(c(script_hash, helper_hashes), collapse = "\n")
  .mr_hash_bytes(charToRaw(combined))
}

# Inline-mode counterpart. The "script bytes" input is the deparsed
# expression supplied by the caller (already computed once in launch()
# for step identity). Helpers contribute the same way as in script mode,
# so a launch({...}) that source()s a helper still reacts to edits in
# that helper.
.mr_code_hash_inline <- function(deparsed_expr, helpers) {
  expr_hash <- .mr_hash_bytes(charToRaw(deparsed_expr))
  helper_hashes <- if (length(helpers) > 0L) sort(unlist(helpers, use.names = FALSE)) else character()
  combined <- paste(c(expr_hash, helper_hashes), collapse = "\n")
  .mr_hash_bytes(charToRaw(combined))
}
