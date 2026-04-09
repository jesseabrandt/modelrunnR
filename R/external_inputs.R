## External inputs declared by launch(..., external_inputs = ...).
##
## Validates and hashes the inputs before the script runs so a missing
## file errors cleanly with nothing half-written to _mr_runs. The
## returned structure is serialized via jsonlite::toJSON and stashed
## in the `external_inputs` column of the run row.

.mr_resolve_external_inputs <- function(external_inputs) {
  if (is.null(external_inputs)) {
    return(list(files = list(), env = list()))
  }
  if (!is.list(external_inputs)) {
    stop("launch(): `external_inputs` must be NULL or a named list.", call. = FALSE)
  }

  files <- external_inputs$files %||% character()
  envs  <- external_inputs$env   %||% character()

  # File hashing (md5 via .mr_file_hash) — missing files error here.
  file_entries <- lapply(files, function(path) {
    if (!file.exists(path)) {
      stop(sprintf("launch(): declared external input file not found: %s", path),
           call. = FALSE)
    }
    list(
      path = normalizePath(path, mustWork = TRUE),
      hash = .mr_file_hash(path)
    )
  })

  # Env var hashing over raw bytes of the value string.
  env_entries <- lapply(envs, function(nm) {
    val <- Sys.getenv(nm, unset = NA_character_)
    hash <- if (is.na(val)) NA_character_ else .mr_hash_bytes(charToRaw(val))
    list(name = nm, hash = hash)
  })

  list(files = file_entries, env = env_entries)
}

.mr_external_inputs_to_json <- function(resolved) {
  jsonlite::toJSON(resolved, auto_unbox = TRUE)
}
