## External inputs declared by launch(..., external_inputs = ...).
##
## Validates and hashes the inputs before the script runs so a missing
## file errors cleanly with nothing half-written to _mr_runs. The
## returned structure is serialized via jsonlite::toJSON and stashed
## in the `external_inputs` column of the run row.

#' Validate and hash declared external inputs before a run
#'
#' @param external_inputs NULL or a named list with `files` and/or `env`
#' @return a list with `files` and `env` entries carrying paths/names and hashes
#' @noRd
.mr_resolve_external_inputs <- function(external_inputs) {
  if (is.null(external_inputs)) {
    return(list(files = list(), env = list()))
  }
  if (!is.list(external_inputs)) {
    stop("launch(): `external_inputs` must be NULL or a named list.", call. = FALSE)
  }

  files <- external_inputs$files %||% character()
  envs  <- external_inputs$env   %||% character()

  # File hashing (md5 via .mr_file_hash) -- missing files error here.
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

#' Serialize resolved external inputs to JSON
#'
#' @param resolved a resolved external-inputs list
#' @return a JSON string for the `external_inputs` run column
#' @noRd
.mr_external_inputs_to_json <- function(resolved) {
  jsonlite::toJSON(resolved, auto_unbox = TRUE)
}

# Inverse of .mr_external_inputs_to_json for the queue -> pickup round
# trip: extract just the *declarations* (paths, env names) from a
# previously-resolved JSON record. Hashes from queue time are
# discarded -- pickup re-resolves so the recorded hashes reflect what
# the body actually saw.
#' Extract external-input declarations (paths, env names) from JSON
#'
#' @param json_text previously-serialized external-inputs JSON
#' @return a list with `files` and `env` declaration vectors, or NULL
#' @noRd
.mr_external_inputs_decl_from_json <- function(json_text) {
  if (is.na(json_text) || !nzchar(json_text)) return(NULL)
  parsed <- tryCatch(
    jsonlite::fromJSON(json_text, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(parsed)) return(NULL)
  files <- vapply(
    parsed$files %||% list(),
    function(e) e$path %||% NA_character_,
    character(1)
  )
  envs <- vapply(
    parsed$env %||% list(),
    function(e) e$name %||% NA_character_,
    character(1)
  )
  files <- files[!is.na(files) & nzchar(files)]
  envs  <- envs[!is.na(envs)   & nzchar(envs)]
  if (length(files) == 0L && length(envs) == 0L) return(NULL)
  list(files = files, env = envs)
}
