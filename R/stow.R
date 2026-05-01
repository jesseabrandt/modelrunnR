#' Persist a value to the modelrunnR artifact store
#'
#' Stores `value` under the logical name `name`. Dispatches on type.
#' The four storage paths are:
#'
#' - **Append table** (for data frames and lazy DuckDB tbls) — writes
#'   into a single growing physical table per `name`, stamping every
#'   row with `_mr_run_id` and `_mr_variant_label`. Running 20 models
#'   that each `stow(<metrics>, "metrics")` produces one 20-row table,
#'   not 20 disjoint versions. Schema drift across runs reconciles
#'   losslessly: new columns are added, missing columns are NULL-filled,
#'   type conflicts coerce to TEXT (never drops a row).
#' - **Versioned artifact** (for any other R object) — serialized via
#'   `qs2`, hashed, and placed in `_mr_artifacts` as a BLOB row when
#'   serialized size is below `getOption("modelrunnR.blob_threshold")`
#'   (default 10 MB) or written to
#'   `<db_dir>/modelrunnR_artifacts/<name>__<hash>.qs2` otherwise. One
#'   version per distinct value; all previous versions stay queryable
#'   via [grab()] selectors.
#' - **Versioned table** (for data frames passed with
#'   `shape = "versioned"`) — hashed, written to a dedicated physical
#'   table per distinct content, and registered in `_mr_versions` (same
#'   path that [ingest()] uses). [mr_file()] values always route through
#'   the file-source path (versioned-shape, source URI/hash recorded).
#' - **View** (for lazy `dbplyr` expressions passed with
#'   `shape = "view"`) — wrapped as `CREATE OR REPLACE VIEW`, hashed
#'   by the rendered SQL text. Inputs referenced in the expression
#'   are resolved against `_mr_versions` and `_mr_append_tables`; an
#'   expression with no managed inputs errors. Source-data staleness
#'   through views over append-shape inputs is a known weak spot —
#'   see `TODO.md` "Surfaced 2026-05-01."
#'
#' A logical name is tied to one shape on first write. Changing shape
#' later (e.g. `stow(df, "x")` then `stow(model, "x")`) errors.
#'
#' Inside a tracked [launch()], each write is recorded on the run row:
#' for append-table writes, as an `append_table` entry keyed by
#' `chunk_hash` (the hash of the rows this run contributed); for
#' artifacts, as a `{name, hash}` pair.
#'
#' Calling `stow()` outside any `launch()` is supported: it mints an
#' `<interactive:TS>` synthetic run row (matching the [ingest()]
#' convention) and stamps the written rows / metadata with that run_id.
#' Downstream launches that [grab()] an interactively-stowed value
#' receive the same reproducibility warning that applies to artifact
#' / ingest inputs.
#'
#' Note on serialization: `qs` is no longer maintained for recent R
#' versions, so modelrunnR uses its successor `qs2` (same fast/compact
#' format).
#'
#' @section Hashing contract:
#' For versioned artifacts, the hash is the serialized-bytes digest.
#' For append tables, the per-call `chunk_hash` is computed over the
#' rows this call contributed (order-independent for the eager frame
#' path; SQL-text-level for the lazy-tbl path — the two hash bases
#' differ, so round-tripping an identical frame through lazy vs eager
#' writes will show distinct chunks in [versions()]). Hashing for
#' DuckDB tables is type-sensitive: integer vs. double columns holding
#' the same values produce different hashes. Row names are not
#' persisted.
#'
#' @param value Any R value. First, so `df |> stow("name")` works.
#' @param name A length-one character vector. Logical name for the
#'   value.
#' @param shape Optional length-1 character. `"versioned"` opts a
#'   data frame into versioned-shape storage (one row per distinct
#'   content); `"append"` makes the default explicit; `"view"`
#'   registers a lazy `dbplyr` expression as a `CREATE OR REPLACE
#'   VIEW`. `NULL` (default) preserves type-based dispatch: data
#'   frames append, non-frame R objects go versioned. `shape = "view"`
#'   requires a lazy `tbl`; `shape = "versioned"` does not work for
#'   lazy tbls (collect to a data frame first).
#' @param label Optional length-1 character. Tags the synthetic
#'   `_mr_runs` row this stow writes with the given variant label,
#'   so later `launch(rebind = list(name = mr_variant(label)))`
#'   resolves to this stow's content. Empty / whitespace-only
#'   labels are rejected. Inside a tracked `launch()`, the label is
#'   taken from the surrounding launch's variant; passing `label =`
#'   to `stow()` from within a launch is therefore redundant and
#'   only affects the synthetic row this stow writes, not the
#'   launch's run row.
#'
#' @section Rolling-window views:
#' Pre-stow one view per fold, then sweep `launch()` with
#' `mr_variant()` to redirect generic input names per fold:
#'
#' ```r
#' panel <- grab("panel")
#' for (i in seq_len(nrow(windows))) {
#'   fold_label <- sprintf("fold_%02d", windows$fold[i])
#'   train_start <- windows$train_start_year[i]
#'   train_end   <- windows$train_end_year[i]
#'   test_yr     <- windows$test_year[i]
#'
#'   panel |>
#'     dplyr::filter(year >= train_start, year <= train_end) |>
#'     stow("train", shape = "view", label = fold_label)
#'   panel |>
#'     dplyr::filter(year == test_yr) |>
#'     stow("test",  shape = "view", label = fold_label)
#' }
#'
#' for (i in seq_len(nrow(windows))) {
#'   fold_label <- sprintf("fold_%02d", windows$fold[i])
#'   launch(model_code, rebind = list(
#'     train = mr_variant(fold_label),
#'     test  = mr_variant(fold_label)
#'   ), label = fold_label)
#' }
#' ```
#'
#' @return `value`, invisibly.
#' @export
stow <- function(value, name, shape = NULL, label = NULL) {
  if (missing(name) && is.character(value) && length(value) == 1L &&
      !inherits(value, "mr_file")) {
    stop(
      "stow() is value-first as of this version: stow(value, name). ",
      "Did you mean `stow(<value>, \"", value, "\")` ?",
      call. = FALSE
    )
  }
  # Also catch the name-first swap when both args are present:
  # stow("preds", df) — value is a scalar string, name is a data frame
  # (or any other non-character payload). Without this, .mr_validate_name
  # fails downstream with a less-useful "name must be a character"
  # message.
  if (!missing(name) && is.character(value) && length(value) == 1L &&
      !inherits(value, "mr_file") &&
      !is.character(name)) {
    stop(
      "stow() is value-first as of this version: stow(value, name). ",
      "Did you mean `stow(<value>, \"", value, "\")` ?",
      call. = FALSE
    )
  }
  .mr_validate_name(name, context = "stow")

  # Validate `shape`; see spec §2 for the dispatch table.
  if (!is.null(shape)) {
    if (!is.character(shape) || length(shape) != 1L ||
        !shape %in% c("versioned", "append", "view")) {
      stop(
        'stow(): shape must be NULL, "versioned", "append", or "view".',
        call. = FALSE
      )
    }
    if (inherits(value, "mr_file")) {
      stop(
        "stow(): mr_file values are always versioned; drop the ",
        "shape argument.",
        call. = FALSE
      )
    }
    if (identical(shape, "view") && !inherits(value, "tbl_lazy")) {
      stop(
        "stow(): shape = 'view' requires a lazy dbplyr expression ",
        "(e.g. grab('name') |> filter(...)). Got: ",
        paste(class(value), collapse = "/"),
        call. = FALSE
      )
    }
    if (!identical(shape, "view") &&
        !is.data.frame(value) && !inherits(value, "tbl_lazy")) {
      stop(
        sprintf(
          "stow(): shape is only meaningful for data frames and lazy tbls; got %s.",
          paste(class(value), collapse = "/")
        ),
        call. = FALSE
      )
    }
  }

  # The shared validator returns NA_character_ for NULL input; downstream
  # plumbing (Tasks 2/3) treats NA the same as "no label". Trimmed value
  # is returned for normalized downstream use.
  label <- .mr_validate_label(label, context = "stow()")

  if (inherits(value, "mr_file")) {
    .mr_guard_namespace(name, shape = "A")
    .mr_stow_file(name, unclass(value), label = label)
    return(invisible(value))
  }

  versioned <- identical(shape, "versioned")

  if (inherits(value, "tbl_lazy")) {
    if (versioned) {
      # tbl_lazy + versioned currently has no first-class path. Surface
      # rather than silently demote to append; the spec scopes
      # versioned-shape opt-in to data frames in §4.
      stop(
        "stow(): shape = 'versioned' is not supported for lazy ",
        "tbls; collect() to a data frame first.",
        call. = FALSE
      )
    }
    if (identical(shape, "view")) {
      .mr_stow_view(name, value, label = label)
      return(invisible(value))
    }
    .mr_guard_namespace(name, shape = "B")
    .mr_append_write_lazy(name, value, label = label)
  } else if (is.data.frame(value)) {
    if (versioned) {
      .mr_guard_namespace(name, shape = "A")
      .mr_stow_table(name, value, label = label)
    } else {
      .mr_guard_namespace(name, shape = "B")
      .mr_append_write_frame(name, value, label = label)
    }
  } else {
    .mr_guard_namespace(name, shape = "A", new_kind = "artifact")
    .mr_stow_artifact(name, value, label = label)
  }
  invisible(value)
}

# Shared implementation for stowing a data frame. Called directly
# by stow() and by ingest() (which additionally updates source
# metadata on the just-written _mr_versions row). Returns the
# content hash invisibly so callers can key UPDATEs off of it
# without re-hashing.
#
# `is_rebind = TRUE` flags the row as a bare-value rebind (written
# from inside .mr_resolve_rebind_entry). The latest-version resolver
# excludes is_rebind rows so they don't shadow real upstream stows.
.mr_stow_table <- function(name, value, is_rebind = FALSE, label = NA_character_) {
  con  <- .mr_get_connection()
  if (.mr_has_nondefault_rownames(value)) {
    warning(
      "stow(): row names are not persisted by the DuckDB backend. ",
      "Convert to a column (e.g. with `tibble::rownames_to_column()`) ",
      "if you need them.",
      call. = FALSE
    )
  }
  # `.mr_hash_frame` creates a DuckDB temp table; DuckDB supports
  # transactional DDL so this is safe to run inside the wrapping
  # transaction below if we choose -- but we hash first so a bad value
  # fails fast before we ever dbBegin().
  hash <- .mr_hash_frame(con, value)
  physical_name <- .mr_physical_name(name, hash)

  existing <- .mr_get_version_row(con, name, hash)
  now <- Sys.time()

  # Atomic write: physical table + _mr_versions row + view refresh must
  # all succeed or all roll back. A crash between them would leave
  # orphaned physical tables or a stale view pointing at nothing.
  DBI::dbBegin(con)
  tryCatch({
    if (nrow(existing) == 0L) {
      .mr_table_write(con, physical_name, value, overwrite = TRUE)
      size_bytes <- as.numeric(object.size(value))
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_versions
           (logical_name, content_hash, physical_name, kind,
            first_seen, last_seen, size_bytes, storage_location, is_rebind)
         VALUES (?, ?, ?, 'table', ?, ?, ?, NULL, ?)",
        params = list(name, hash, physical_name, now, now, size_bytes,
                      isTRUE(is_rebind))
      )
    } else {
      DBI::dbExecute(
        con,
        "UPDATE _mr_versions
           SET last_seen = ?
         WHERE logical_name = ? AND content_hash = ?",
        params = list(now, name, hash)
      )
    }
    .mr_refresh_latest_view(con, name)
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    stop(e)
  })

  .mr_record_write(name, hash)
  .mr_maybe_record_interactive_write(name, hash, label = label)
  .mr_maybe_warn_version_count(con, name)
  invisible(hash)
}

# Store a non-data-frame R object as an artifact. Blob for small
# payloads, filesystem for large ones, with the choice gated by
# modelrunnR.blob_threshold (default 10 MB).
#
# `is_rebind = TRUE` flags the row as a bare-value rebind (written
# from inside .mr_resolve_rebind_entry). See .mr_stow_table for
# rationale.
.mr_stow_artifact <- function(name, value, is_rebind = FALSE, label = NA_character_) {
  con   <- .mr_get_connection()
  bytes <- qs2::qs_serialize(value)
  hash  <- .mr_hash_bytes(bytes)
  size  <- length(bytes)

  threshold <- getOption("modelrunnR.blob_threshold", 10L * 1024L * 1024L)
  storage   <- if (size < threshold) "blob" else "file"

  existing <- .mr_get_version_row(con, name, hash)
  now <- Sys.time()

  if (nrow(existing) == 0L) {
    physical_name <- if (storage == "blob") {
      .mr_physical_name(name, hash)
    } else {
      .mr_artifact_file_path(name, hash)
    }

    # For filesystem artifacts: write the file before starting the
    # transaction, so if the file write itself fails we haven't begun a
    # transaction. If the later INSERT rolls back, we delete the file in
    # the error handler so no orphan is left behind.
    file_written <- FALSE
    if (storage == "file") {
      dir.create(dirname(physical_name), recursive = TRUE, showWarnings = FALSE)
      writeBin(bytes, physical_name)
      file_written <- TRUE
    }

    DBI::dbBegin(con)
    tryCatch({
      if (storage == "blob") {
        DBI::dbExecute(
          con,
          "INSERT INTO _mr_artifacts (physical_name, payload) VALUES (?, ?)",
          params = list(physical_name, list(bytes))
        )
      }
      DBI::dbExecute(
        con,
        "INSERT INTO _mr_versions
           (logical_name, content_hash, physical_name, kind,
            first_seen, last_seen, size_bytes, storage_location, is_rebind)
         VALUES (?, ?, ?, 'artifact', ?, ?, ?, ?, ?)",
        params = list(name, hash, physical_name, now, now, size, storage,
                      isTRUE(is_rebind))
      )
      DBI::dbCommit(con)
    }, error = function(e) {
      DBI::dbRollback(con)
      # Clean up the orphaned file artifact so crash-then-fix doesn't
      # leave untracked bytes on disk.
      if (file_written) try(file.remove(physical_name), silent = TRUE)
      stop(e)
    })
  } else {
    DBI::dbExecute(
      con,
      "UPDATE _mr_versions
         SET last_seen = ?
       WHERE logical_name = ? AND content_hash = ?",
      params = list(now, name, hash)
    )
  }

  .mr_record_write(name, hash)
  .mr_maybe_record_interactive_write(name, hash, label = label)
  .mr_maybe_warn_version_count(con, name)
  invisible(hash)
}

## Internals ------------------------------------------------------------------

.mr_maybe_warn_version_count <- function(con, name) {
  threshold <- getOption("modelrunnR.version_warn_threshold", 20L)
  count <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS c FROM _mr_versions WHERE logical_name = ?",
    params = list(name)
  )$c[1]
  if (count > threshold) {
    warning(sprintf(
      "'%s' has %d versions (threshold: %d). Consider running prune('%s', ...) to reclaim storage.",
      name, count, threshold, name
    ), call. = FALSE)
  }
  invisible(NULL)
}

.mr_physical_name <- function(name, hash) {
  sprintf("%s__%s", name, substr(hash, 1L, 16L))
}

.mr_artifact_file_path <- function(name, hash) {
  # Artifacts live next to the DuckDB file so they travel with it.
  dir <- file.path(dirname(db_path()), "modelrunnR_artifacts")
  file.path(dir, sprintf("%s__%s.qs2", name, substr(hash, 1L, 16L)))
}

.mr_get_version_row <- function(con, name, hash) {
  DBI::dbGetQuery(
    con,
    "SELECT * FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
    params = list(name, hash)
  )
}

.mr_refresh_latest_view <- function(con, name) {
  # Tables (kind='table') and SQL views (kind='view') both expose a
  # physical relation queryable via SELECT * FROM <physical>. Either
  # kind can back the latest-version convenience view at <logical>.
  #
  # Bare-value rebinds (is_rebind = TRUE) are excluded so a launch that
  # rebound `name` to a sample frame doesn't shadow the real upstream:
  # naked `grab(name)` after the launch still resolves to the canonical
  # latest version.
  latest <- DBI::dbGetQuery(
    con,
    "SELECT physical_name FROM _mr_versions
      WHERE logical_name = ? AND kind IN ('table', 'view')
        AND (is_rebind IS NOT TRUE)
      ORDER BY first_seen DESC
      LIMIT 1",
    params = list(name)
  )
  if (nrow(latest) == 0L) {
    # No versions left (prune-all). Drop the dangling view so direct
    # SQL against the logical name fails cleanly instead of pointing at
    # a dropped physical table.
    .mr_execute(
      con,
      sprintf("DROP VIEW IF EXISTS %s", .mr_quote_ident(name))
    )
    return(invisible(NULL))
  }
  sql <- sprintf(
    "CREATE OR REPLACE VIEW %s AS SELECT * FROM %s",
    .mr_quote_ident(name),
    .mr_quote_ident(latest$physical_name[1])
  )
  .mr_execute(con, sql)
  invisible(NULL)
}

