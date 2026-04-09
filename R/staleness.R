## Pre-run staleness diagnostics.
##
## A step is **stale** when any of:
##   1. It has never been run before.
##   2. Its script bytes or any recorded helper's bytes have changed.
##   3. Any recorded input's current content hash differs from the
##      hash recorded at the time of the last run.
##   4. Any declared external input's current hash differs.
##
## Advisory by design: `.mr_is_stale()` reports state; `launch()`
## surfaces the info but never auto-skips.

#' Check whether a step is stale relative to its most recent run
#'
#' Compares the current state of the script file, its recorded
#' helpers, its recorded inputs, and its recorded external inputs
#' against the most recent `_mr_runs` row for this step. Returns a
#' list with `stale` (logical) and `reasons` (character vector).
#'
#' @param step Normalized path to the step's script file.
#'
#' @return A list with fields `stale` and `reasons`.
#' @keywords internal
.mr_is_stale <- function(step) {
  con <- .mr_get_connection()
  prior <- DBI::dbGetQuery(
    con,
    "SELECT code_hash, inputs, external_inputs, helpers
       FROM _mr_runs
      WHERE step = ?
      ORDER BY started_at DESC
      LIMIT 1",
    params = list(step)
  )
  if (nrow(prior) == 0L) {
    return(list(stale = TRUE, reasons = "never_run"))
  }

  reasons <- character()

  # 1 & 2: code hash arm -- reconstruct using current helper bytes but
  # the prior-known helper path list, and compare to the prior code_hash.
  reasons <- c(reasons, .mr_check_code_hash(step, prior))

  # 3: input hash arm -- iterate recorded inputs and compare to the
  # current latest version of each logical name.
  reasons <- c(reasons, .mr_check_inputs(con, prior$inputs[1]))

  # 4: external input arm -- recompute each declared file/env hash.
  reasons <- c(reasons, .mr_check_external_inputs(prior$external_inputs[1]))

  list(stale = length(reasons) > 0L, reasons = reasons)
}

.mr_check_code_hash <- function(step, prior) {
  if (!file.exists(step)) return("code")

  helpers_json <- prior$helpers[1]
  helpers <- if (is.na(helpers_json) || !nzchar(helpers_json)) {
    list()
  } else {
    jsonlite::fromJSON(helpers_json, simplifyVector = FALSE)
  }

  # Rebuild the (path -> current hash) list using the prior helper paths.
  current_helpers <- list()
  code_reason <- character()
  for (h in helpers) {
    if (!file.exists(h$path)) {
      return("code")  # helper disappeared -> treat as changed
    }
    current_helpers[[h$path]] <- .mr_hash_bytes(.mr_read_file_bytes(h$path))
  }

  current_code_hash <- .mr_code_hash(step, current_helpers)
  prior_code_hash   <- prior$code_hash[1]
  if (is.na(prior_code_hash)) {
    # Pre-Slice-7 runs didn't record a code hash. Distinguish this from
    # an actual mismatch so users upgrading an existing .duckdb can
    # tell "we don't know" from "you edited the script".
    return("code_unknown")
  }
  if (!identical(current_code_hash, prior_code_hash)) {
    return("code")
  }
  code_reason
}

.mr_check_inputs <- function(con, inputs_json) {
  if (is.na(inputs_json) || !nzchar(inputs_json) || inputs_json == "[]") {
    return(character())
  }
  pairs <- jsonlite::fromJSON(inputs_json, simplifyVector = FALSE)
  reasons <- character()
  for (p in pairs) {
    row <- DBI::dbGetQuery(
      con,
      "SELECT content_hash FROM _mr_versions
        WHERE logical_name = ?
        ORDER BY first_seen DESC
        LIMIT 1",
      params = list(p$name)
    )
    current <- if (nrow(row) == 0L) NA_character_ else row$content_hash[1]
    if (is.na(current) || !identical(current, p$hash)) {
      reasons <- c(reasons, sprintf("input:%s", p$name))
    }
  }
  reasons
}

.mr_check_external_inputs <- function(external_json) {
  if (is.na(external_json) || !nzchar(external_json)) {
    return(character())
  }
  ext <- tryCatch(
    jsonlite::fromJSON(external_json, simplifyVector = FALSE),
    error = function(e) list()
  )
  reasons <- character()
  # jsonlite round-trips NA_character_ as `null` -> R NULL on read, so
  # recorded hashes must be coerced back to NA_character_ before
  # comparison. Without this, any env var that was unset at resolve time
  # compares NA to NULL via `identical()` and always reports stale.
  for (f in (ext$files %||% list())) {
    prior <- f$hash %||% NA_character_
    if (!file.exists(f$path) ||
        !identical(.mr_file_hash(f$path), prior)) {
      reasons <- c(reasons, sprintf("external:%s", f$path))
    }
  }
  for (e in (ext$env %||% list())) {
    val <- Sys.getenv(e$name, unset = NA_character_)
    current <- if (is.na(val)) NA_character_ else .mr_hash_bytes(charToRaw(val))
    prior   <- e$hash %||% NA_character_
    # Both NA means: was unset then, still unset now -- not stale.
    if (is.na(current) && is.na(prior)) next
    if (!identical(current, prior)) {
      reasons <- c(reasons, sprintf("external:env:%s", e$name))
    }
  }
  reasons
}
