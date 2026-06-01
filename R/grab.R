#' Retrieve a value from the modelrunnR artifact store
#'
#' modelrunnR stores tabular values two ways — as **versioned** snapshots
#' (one row per distinct content) and as **append tables** (one growing
#' table, row-stamped per run). `grab()` dispatches on which shape `name`
#' was stored as, so the same call works regardless. The distinction is
#' explained in the Getting Started vignette.
#'
#' **Versioned (Shape A)** — data the package treats as immutable: ingested
#' reference data, non-tabular artifacts (models, lists, results). The
#' default returns the current latest version; historical versions can be
#' selected via `version` (content hash), `from_run` (run id), or `as_of`
#' (timestamp), in that precedence order. Pass `run = "all"` to get a
#' **named list** of every stored version (one element per content hash,
#' ordered oldest -> newest).
#'
#' **Append (Shape B)** — data frames you `stow()` inside runs. The default
#' returns one coherent snapshot — the rows from a single run — with system
#' columns (`_mr_run_id`, `_mr_variant_label`) stripped, so `grab(name)`
#' gives you user columns only. Which run depends on context: inside a
#' [launch()] block it is the *current* run (rows this run has written so
#' far); outside a launch it is the *latest* run that wrote to `name`. The
#' exploratory workflow — `grab("metrics") |> collect()` at the REPL —
#' thus pulls a clean slice rather than the accumulated cross-run pile.
#' Pass `run = "all"` to opt into the full-history view: every row, with
#' system columns surfaced as user-facing `run_id` and `variant_label`
#' columns — the right lens for comparing runs.
#'
#' Inside a tracked [launch()], the read is recorded as an input
#' `{name, hash}` pair on the run row. Outside a launch, the read
#' is not logged.
#'
#' When `source` is supplied, `grab()` behaves as an idempotent
#' read-or-ingest: if `name` does not exist yet, an implicit
#' `stow(mr_file(source), name)` is performed. If `name` exists and
#' the file's current content hash differs from the latest stored
#' `source_hash`, the file is re-stowed and a new version is created.
#' If the file is unchanged, the cached version is returned.
#'
#' @param name A length-one character vector naming a logical value.
#' @param version Optional content hash (as returned by [versions()])
#'   to select a specific stored version. Shape A only.
#' @param from_run Optional run id (as returned by [launch()]'s
#'   invisibly-returned run row) to select the exact version produced
#'   by that run. For Shape B tables, filters to rows from that run.
#' @param as_of Optional `POSIXct` timestamp; returns the version
#'   that was latest at that time. Shape A only.
#' @param source Optional path to a CSV or Parquet file. Triggers an
#'   implicit `stow(mr_file(source), name)` when the file hash
#'   differs from (or is not yet present in) the stored source
#'   metadata.
#' @param variant Optional string; resolves to the latest version produced
#'   by any run launched with `label = variant`. Mutually exclusive with
#'   `version`, `from_run`, `as_of`, and `run`. See *Variants and
#'   swappability* in docs/design.md for the full semantics.
#' @param run Cross-history selector. On Shape B (append tables), a run id
#'   string filters to that run's rows, or `"all"` returns every row with
#'   `run_id` and `variant_label` exposed. On Shape A (versioned), only
#'   `"all"` is accepted and returns a named list of every stored version
#'   keyed by `content_hash`.
#'
#' @section Security note:
#' Artifacts stored via [stow()] are deserialized on read with
#' `qs2::qs_deserialize()`. Opening a project produced by someone else
#' trusts the artifacts to the same extent as trusting that party's R
#' code: `qs2` does not have `readRDS`'s historical callback
#' arbitrary-code-execution surface, but it has not been independently
#' audited. Do not `grab()` from projects you would not `source()`.
#'
#' @return For tabular stored values (ingested files, stowed data
#'   frames), a `dbplyr` lazy `tbl` bound to the modelrunnR DuckDB
#'   connection. Compose `dplyr` verbs against it and call
#'   [dplyr::collect()] (or [as.data.frame()] / [tibble::as_tibble()])
#'   to materialize. For non-tabular artifacts, the deserialized R
#'   object.
#' @export
grab <- function(name, version = NULL, from_run = NULL, as_of = NULL,
                 source = NULL, variant = NULL, run = NULL) {
  .mr_validate_name(name, context = "grab")
  con <- .mr_get_connection()

  selectors <- c(!is.null(version), !is.null(from_run),
                 !is.null(as_of),   !is.null(variant),
                 !is.null(run))
  if (sum(selectors) > 1L) {
    stop("grab(): more than one selector passed; specify at most one of ",
         "`version`, `from_run`, `as_of`, `variant`, `run`.",
         call. = FALSE)
  }

  if (!is.null(source)) {
    .mr_maybe_ingest(con, name, source)
  }

  shape <- .mr_lookup_shape(name)

  if (identical(shape, "B")) {
    if (!is.null(version) || !is.null(as_of)) {
      stop(sprintf(
        "grab(): '%s' is an append table (Shape B). Use `run=`, `variant=`, or `from_run=`; %s does not apply.",
        name, if (!is.null(version)) "`version`" else "`as_of`"
      ), call. = FALSE)
    }
    if (!is.null(run)) {
      reading <- .mr_append_read(name, run = run)
      # `run = "all"` is a cross-history view; no single chunk_hash applies.
      hash <- if (identical(run, "all")) {
        NA_character_
      } else {
        .mr_append_chunk_hash_for_run(con, name, run)
      }
      .mr_record_read(name, hash)
      return(reading)
    }
    if (!is.null(variant)) {
      reading <- .mr_append_read(name, variant = variant)
      .mr_record_read(name, .mr_append_latest_chunk_hash_for_variant(con, name, variant))
      return(reading)
    }
    if (!is.null(from_run)) {
      reading <- .mr_append_read(name, run = from_run)
      .mr_record_read(name, .mr_append_chunk_hash_for_run(con, name, from_run))
      return(reading)
    }
    # If this name is rebound to a specific filter, honor it before the
    # launch-context default so explicit rebinds override "current run".
    rebound_filter <- .mr_rebound_shape_b_filter(name)
    if (!is.null(rebound_filter)) {
      reading <- .mr_append_read(name, run = rebound_filter$value)
      .mr_record_read(name, .mr_append_chunk_hash_for_run(con, name, rebound_filter$value))
      return(reading)
    }

    # Default: launch-context aware.
    current_run <- .mr_recording_run_id()
    reading <- if (!is.null(current_run) && !is.na(current_run)) {
      .mr_append_read(name, run = current_run)
    } else {
      .mr_append_read(name)
    }
    # Record the upstream's latest chunk_hash at the time of read so a
    # downstream consumer goes stale when the upstream appends a new
    # chunk. Mirrors the SQL-launch `inputs_pairs` recording (see
    # .mr_launch_sql, Shape B branch).
    .mr_record_read(name, .mr_append_latest_chunk_hash(con, name))
    return(reading)
  }

  # Shape A — existing path (preserve behavior)
  if (!is.null(run)) {
    # Shape-invisibility: `run = "all"` on Shape A returns a named list
    # of every stored version (oldest -> newest), using content_hash as
    # the list name. Mirrors the "stack everything" spirit of Shape B's
    # `run = "all"` but surfaces content hashes where Shape B surfaces
    # run_ids. Other `run=` values error — there is no run-level
    # identity for a content-addressed value.
    if (identical(run, "all")) {
      v <- DBI::dbGetQuery(
        con,
        "SELECT * FROM _mr_versions WHERE logical_name = ? ORDER BY first_seen",
        params = list(name)
      )
      if (nrow(v) == 0L) {
        stop(sprintf("grab(): no versions of '%s' found", name), call. = FALSE)
      }
      out <- vector("list", nrow(v))
      for (i in seq_len(nrow(v))) {
        out[[i]] <- .mr_read_value(con, v[i, , drop = FALSE])
      }
      names(out) <- v$content_hash
      .mr_record_read(name, NA_character_)
      return(out)
    }
    stop(sprintf(
      "grab(): `run=` on versioned name '%s' only accepts \"all\"; for a specific historical value use `version=` (content hash) or `from_run=` (run id).",
      name
    ), call. = FALSE)
  }
  if (!is.null(variant)) {
    return(.mr_grab_by_variant(name, variant))
  }

  # If a launch has rebound this name and the caller didn't provide
  # an explicit selector, resolve via the rebound content hash.
  if (is.null(version) && is.null(from_run) && is.null(as_of)) {
    rebound <- .mr_rebound_hash(name)
    if (!is.null(rebound)) version <- rebound
  }

  resolved <- .mr_resolve_version(con, name, version, from_run, as_of)
  .mr_record_read(name, resolved$content_hash)
  .mr_read_value(con, resolved)
}

# Given a _mr_versions row, return the stored value. Tables and SQL
# views both go through dplyr::tbl() so callers get a lazy dbplyr
# reference (DuckDB inlines the view definition at query-plan time, so
# the consumer cannot tell the two apart). Artifacts are fetched from
# `_mr_artifacts` (for BLOB storage) or read from disk (for filesystem
# storage) and then deserialized via qs2.
#' Materialize a stored value from its _mr_versions row
#'
#' Returns a lazy `dbplyr` tbl for tables/views, or the deserialized
#' R object for artifacts (read from BLOB or disk per storage location).
#'
#' @param con An active DuckDB connection.
#' @param row A single-row `_mr_versions` data frame.
#' @return A lazy `tbl` (tables/views) or the deserialized artifact.
#' @noRd
.mr_read_value <- function(con, row) {
  if (identical(row$kind, "table") || identical(row$kind, "view")) {
    return(dplyr::tbl(con, row$physical_name))
  }
  # artifact
  if (identical(row$storage_location, "blob")) {
    blob <- DBI::dbGetQuery(
      con,
      "SELECT payload FROM _mr_artifacts WHERE physical_name = ?",
      params = list(row$physical_name)
    )
    if (nrow(blob) == 0L) {
      stop(sprintf("grab(): artifact payload missing for '%s' (pruned?)",
                   row$physical_name), call. = FALSE)
    }
    bytes <- blob$payload[[1]]
    return(qs2::qs_deserialize(bytes))
  }
  # storage == "file"
  if (!file.exists(row$physical_name)) {
    stop(sprintf("grab(): artifact file missing: %s", row$physical_name), call. = FALSE)
  }
  bytes <- readBin(row$physical_name, what = "raw", n = file.info(row$physical_name)$size)
  qs2::qs_deserialize(bytes)
}

# Called by grab(source = ...). Ingests when either (a) the name has
# never been stored or (b) the current file's md5 differs from the
# latest stored source_hash. Silently no-ops otherwise.
#' Conditionally ingest a source file for grab(source = ...)
#'
#' Stows the file when `name` has no real upstream version yet, or when
#' the file's current hash differs from the latest stored source hash;
#' otherwise no-ops.
#'
#' @param con An active DuckDB connection.
#' @param name Logical name to ingest under.
#' @param source Path to the source CSV/Parquet file.
#' @return `NULL`, invisibly.
#' @noRd
.mr_maybe_ingest <- function(con, name, source) {
  # Existence check excludes rebind rows: a name that only exists as a
  # bare-value rebind has no real upstream, so grab(source=) should
  # ingest from the supplied path.
  existing <- DBI::dbGetQuery(
    con,
    "SELECT 1 FROM _mr_versions
       WHERE logical_name = ? AND (is_rebind IS NOT TRUE) LIMIT 1",
    params = list(name)
  )
  if (nrow(existing) == 0L) {
    .mr_stow_file(name, source)
    return(invisible(NULL))
  }
  current <- .mr_file_hash(source)
  stored  <- .mr_latest_source_hash(con, name)
  if (is.na(stored) || !identical(current, stored)) {
    .mr_stow_file(name, source)
  }
  invisible(NULL)
}

## Internals ------------------------------------------------------------------

# Resolve (logical_name + optional selector) to a _mr_versions row.
# Returns a single-row data frame or stops with a clear error.
#' Resolve a logical name plus optional selector to a version row
#'
#' Applies `version`, `from_run`, `as_of` in that precedence order,
#' falling back to the latest non-rebind version. Stops with a clear
#' error when nothing matches.
#'
#' @param con An active DuckDB connection.
#' @param name Logical name to resolve.
#' @param version Optional content hash selector.
#' @param from_run Optional run id selector.
#' @param as_of Optional `POSIXct` timestamp selector.
#' @return A single-row `_mr_versions` data frame.
#' @noRd
.mr_resolve_version <- function(con, name, version, from_run, as_of) {
  if (!is.null(version)) {
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
      params = list(name, version)
    )
    if (nrow(row) == 0L) {
      stop(sprintf("grab(): version '%s' for '%s' not found", version, name),
           call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  if (!is.null(from_run)) {
    run <- DBI::dbGetQuery(
      con,
      "SELECT outputs FROM _mr_runs WHERE run_id = ?",
      params = list(from_run)
    )
    if (nrow(run) == 0L) {
      stop(sprintf("grab(): no run with run_id '%s'", from_run), call. = FALSE)
    }
    # Legacy/hand-edited rows can have NA or empty outputs; guard the
    # JSON parse rather than crash with an opaque jsonlite error.
    pairs <- if (is.na(run$outputs[1]) || !nzchar(run$outputs[1])) {
      list()
    } else {
      tryCatch(
        jsonlite::fromJSON(run$outputs[1], simplifyVector = FALSE),
        error = function(e) list()
      )
    }
    hash <- NULL
    for (p in pairs) {
      if (identical(p$name, name)) { hash <- p$hash; break }
    }
    if (is.null(hash)) {
      stop(sprintf("grab(): run '%s' did not produce '%s'", from_run, name),
           call. = FALSE)
    }
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
      params = list(name, hash)
    )
    if (nrow(row) == 0L) {
      stop(sprintf(
        "grab(): version '%s' for '%s' not found - the run's output has been pruned.",
        hash, name
      ), call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  if (!is.null(as_of)) {
    # DuckDB TIMESTAMP columns are timezone-naive. Parse string inputs
    # as UTC so `grab(as_of = "...")` is reproducible across machines
    # regardless of session `TZ`. Users who need a local-time reading
    # should pass an explicit POSIXct.
    if (!inherits(as_of, "POSIXct")) as_of <- as.POSIXct(as_of, tz = "UTC")
    row <- DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions
         WHERE logical_name = ? AND first_seen <= ?
           AND (is_rebind IS NOT TRUE)
         ORDER BY first_seen DESC
         LIMIT 1",
      params = list(name, as_of)
    )
    if (nrow(row) == 0L) {
      stop(sprintf("grab(): no version of '%s' existed at %s", name, format(as_of)),
           call. = FALSE)
    }
    return(row[1, , drop = FALSE])
  }

  # Default: latest version for this name. Bare-value rebind rows
  # (is_rebind = TRUE) are excluded so a launch that rebound `name` to a
  # sample value doesn't shadow the real upstream — naked grab(name)
  # still resolves to the canonical latest stow.
  row <- DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_versions
       WHERE logical_name = ?
         AND (is_rebind IS NOT TRUE)
       ORDER BY first_seen DESC
       LIMIT 1",
    params = list(name)
  )
  if (nrow(row) == 0L) {
    stop(sprintf("grab(): no value stowed under '%s'", name), call. = FALSE)
  }
  row[1, , drop = FALSE]
}

# Read a stored value by (logical_name, content_hash). Fetches the
# _mr_versions row and delegates to .mr_read_value().
#' Read a stored value by logical name and content hash
#'
#' @param con An active DuckDB connection.
#' @param name Logical name.
#' @param hash Content hash to resolve.
#' @return The materialized value (lazy `tbl` or deserialized artifact).
#' @noRd
.mr_read_by_hash <- function(con, name, hash) {
  row <- DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
    params = list(name, hash)
  )
  if (nrow(row) == 0L) {
    stop(sprintf("grab(): version '%s' for '%s' not found (pruned?)",
                 hash, name), call. = FALSE)
  }
  .mr_read_value(con, row[1, , drop = FALSE])
}

#' Grab the latest version produced by a given variant
#'
#' @param name Logical name to read.
#' @param variant Variant label whose latest output of `name` to fetch.
#' @return The materialized value for the resolved version.
#' @noRd
.mr_grab_by_variant <- function(name, variant) {
  con  <- .mr_get_connection()
  hash <- .mr_latest_hash_for_variant(con, name, variant)
  if (is.null(hash)) {
    stop(sprintf("grab(): no variant named '%s' has produced '%s'.",
                 variant, name), call. = FALSE)
  }
  .mr_record_read(name, hash)
  .mr_read_by_hash(con, name, hash)
}

#' Find the latest content hash produced for a name under a variant
#'
#' Walks `_mr_runs` rows with the given `variant_label` newest-first,
#' parsing `outputs` JSON until one produced `name`.
#'
#' @param con An active DuckDB connection.
#' @param name Logical name to look for in run outputs.
#' @param variant Variant label to filter runs by.
#' @return The matching content hash, or `NULL` if none.
#' @noRd
.mr_latest_hash_for_variant <- function(con, name, variant) {
  # Walk _mr_runs for rows with this variant_label, parse outputs
  # JSON, pick the most recent one that produced `name`.
  rows <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs
      WHERE variant_label = ?
      ORDER BY started_at DESC",
    params = list(variant)
  )
  if (nrow(rows) == 0L) return(NULL)
  for (j in seq_len(nrow(rows))) {
    raw <- rows$outputs[j]
    pairs <- if (is.na(raw) || !nzchar(raw)) {
      list()
    } else {
      tryCatch(
        jsonlite::fromJSON(raw, simplifyVector = FALSE),
        error = function(e) list()
      )
    }
    for (p in pairs) {
      if (identical(p$name, name)) return(p$hash)
    }
  }
  NULL
}
