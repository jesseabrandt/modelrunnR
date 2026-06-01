## L0 source snapshot: persist the bytes of a code body and its
## helpers to `_mr_code` / `_mr_code_helpers` so any run row can be
## traced back to recoverable source bytes via its `code_hash`.
##
## Design choices (locked in 2026-05-13, see
## docs/superpowers/specs/2026-05-13-code-snapshot-design.md):
##
## - Helper bytes live in a separate `_mr_code_helpers` join table so
##   helpers shared across many runs aren't duplicated per code_hash.
## - Snapshot writes BLOCK the launch on failure -- L0 is a contract,
##   not telemetry. A DB write failure surfaces as a launch error
##   rather than letting a run row land without recoverable source.
## - Idempotent on `code_hash`: a `_mr_code` row that already exists is
##   left alone; helper rows are skipped if any are already present
##   for the same `code_hash` (presence implies a complete prior write).
##
## The recorder fires from `.mr_launch_one()` and `.mr_launch_sql()`
## after `code_hash` is computed and before the run row is written, so
## the snapshot is committed (or fails) before any run row records the
## hash. Skipped-fresh runs do not re-snapshot: their `code_hash` was
## inherited from a prior `status = 'success'` row whose source is
## already in `_mr_code`.

#' Persist a code body and its helpers to the L0 source snapshot store
#'
#' @param con a DBI connection to the modelrunnR store.
#' @param code_hash content hash keying the snapshot; NA/empty is a no-op.
#' @param script_path source path of the script, or NA for inline.
#' @param script_bytes raw bytes of the code body (NULL coerced to zero bytes).
#' @param helpers_with_bytes list of helper records with path, hash, and bytes.
#' @param inline TRUE if the code body is an inline block.
#' @return Invisibly, NULL (called for its side effect).
#' @noRd
.mr_record_code_snapshot <- function(con,
                                     code_hash,
                                     script_path,
                                     script_bytes,
                                     helpers_with_bytes = list(),
                                     inline = FALSE) {
  if (is.na(code_hash) || !nzchar(code_hash)) return(invisible(NULL))

  existing <- DBI::dbGetQuery(
    con,
    "SELECT 1 FROM _mr_code WHERE code_hash = ? LIMIT 1",
    params = list(code_hash)
  )
  if (nrow(existing) > 0L) return(invisible(NULL))

  if (is.null(script_bytes)) script_bytes <- raw(0)
  resolved_path <- if (is.null(script_path) || is.na(script_path)) {
    NA_character_
  } else {
    script_path
  }

  # `INSERT ... ON CONFLICT DO NOTHING` covers the race where two
  # callers both passed the existence pre-check and would otherwise
  # collide on the PRIMARY KEY. The existence check above remains as
  # a fast-path that also short-circuits the helper-row inserts.
  # Parameterized dbExecute matches the `_mr_artifacts` BLOB-insert
  # idiom in R/stow.R: raw vectors wrap one level via list().
  DBI::dbExecute(
    con,
    "INSERT INTO _mr_code
       (code_hash, script_path, script_bytes, inline, recorded_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (code_hash) DO NOTHING",
    params = list(
      code_hash,
      resolved_path,
      list(script_bytes),
      isTRUE(inline),
      Sys.time()
    )
  )

  if (length(helpers_with_bytes) > 0L) {
    for (h in helpers_with_bytes) {
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_code_helpers
           (code_hash, helper_path, helper_hash, helper_bytes)
         VALUES (?, ?, ?, ?)",
        params = list(
          code_hash,
          h$path,
          h$hash,
          list(h$bytes %||% raw(0))
        )
      )
    }
  }

  invisible(NULL)
}

# Coerce a code_body string to a raw vector suitable for the BLOB
# column. NULL and NA are treated as a zero-byte payload; otherwise
# `charToRaw()` produces the bytes. Kept centralized so every launch
# hook applies the same NA/NULL handling.
#' Coerce a code body string to raw bytes for the snapshot BLOB column
#'
#' @param code_body the code body text; NULL or NA yields zero bytes.
#' @return A raw vector of the code body bytes.
#' @noRd
.mr_script_bytes_for_snapshot <- function(code_body) {
  if (is.null(code_body)) return(raw(0))
  if (length(code_body) != 1L || is.na(code_body)) return(raw(0))
  charToRaw(code_body)
}

# Build the `helpers_with_bytes` list expected by .mr_record_code_snapshot
# from the parallel (path -> hash) and (path -> raw) maps tracked
# during a launch. Path order follows `names(hashes)`; an unmatched
# bytes entry is dropped (caller-side bug, not a runtime concern).
#' Build the helpers-with-bytes list from parallel hash and bytes maps
#'
#' @param hashes named (path -> hash) map of tracked helpers.
#' @param bytes named (path -> raw) map of helper bytes.
#' @return A list of helper records, each with path, hash, and bytes.
#' @noRd
.mr_pack_helpers <- function(hashes, bytes) {
  if (length(hashes) == 0L) return(list())
  paths <- names(hashes)
  out <- vector("list", length(paths))
  for (i in seq_along(paths)) {
    p <- paths[[i]]
    out[[i]] <- list(
      path  = p,
      hash  = hashes[[p]],
      bytes = bytes[[p]] %||% raw(0)
    )
  }
  out
}

# Internal reader: round-trip the snapshot back out of the store.
# Returns NULL when `code_hash` is unknown. Helpers come back in the
# order they were inserted (which mirrors source-time discovery for
# helper_tracking, and is stable within one code_hash).
#' Load a code snapshot and its helpers back out of the store
#'
#' @param con a DBI connection to the modelrunnR store.
#' @param code_hash content hash of the snapshot to load; NA/empty returns NULL.
#' @return A list of the snapshot fields and helpers, or NULL if not found.
#' @noRd
.mr_load_code <- function(con, code_hash) {
  if (is.na(code_hash) || !nzchar(code_hash)) return(NULL)

  code <- DBI::dbGetQuery(
    con,
    "SELECT code_hash, script_path, script_bytes, inline, recorded_at
       FROM _mr_code WHERE code_hash = ?",
    params = list(code_hash)
  )
  if (nrow(code) == 0L) return(NULL)

  helpers_df <- DBI::dbGetQuery(
    con,
    "SELECT helper_path, helper_hash, helper_bytes
       FROM _mr_code_helpers WHERE code_hash = ?",
    params = list(code_hash)
  )
  helpers <- if (nrow(helpers_df) == 0L) {
    list()
  } else {
    lapply(seq_len(nrow(helpers_df)), function(i) {
      list(
        path  = helpers_df$helper_path[[i]],
        hash  = helpers_df$helper_hash[[i]],
        bytes = helpers_df$helper_bytes[[i]]
      )
    })
  }

  list(
    code_hash    = code$code_hash[[1L]],
    script_path  = code$script_path[[1L]],
    script_bytes = code$script_bytes[[1L]],
    inline       = isTRUE(code$inline[[1L]]),
    recorded_at  = code$recorded_at[[1L]],
    helpers      = helpers
  )
}
