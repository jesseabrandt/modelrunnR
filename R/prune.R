#' Prune stored values
#'
#' Remove stored data from the modelrunnR store. Works on both storage
#' shapes:
#'
#' - **Versioned (Shape A)** — drops entire `(name, content_hash)` rows
#'   from `_mr_versions` and their physical artifacts.
#' - **Append (Shape B)** — deletes rows from the growing append table
#'   by `run_id` / age, keeping the registry row so the accumulator
#'   still exists under its logical name.
#'
#' Dispatches on the shape of `name`. Without `name`, applies the
#' policy to every logical name in the store (both shapes).
#'
#' @param name Optional logical name to restrict pruning to.
#' @param by One of `"auto"`, `"version"`, `"run"`, `"age"`. The default
#'   `"auto"` dispatches on shape. `"version"` requires a Shape A name;
#'   `"run"` requires a Shape B name; `"age"` is a shape-agnostic
#'   shortcut that uses only `older_than`.
#' @param run_id Character vector of run ids to prune (Shape B only).
#' @param keep Integer; keep the N most recent versions (Shape A) or
#'   runs (Shape B). Applied per logical name.
#' @param keep_latest Logical; shorthand for `keep = 1`. Shape A only.
#' @param older_than Duration string (`"30d"`, `"6h"`, `"15m"`,
#'   `"45s"`). Works on both shapes.
#' @param force Logical. If `TRUE`, overrides protection (run-referenced
#'   versions on Shape A, variant-labeled runs on Shape B).
#'
#' @return Invisibly. For a single-shape call, a data frame describing
#'   what was pruned. For calls that span both shapes (`name = NULL`
#'   with `by = "auto"`, or `by = "age"`), a list with `$versioned` and
#'   `$append` data frames.
#' @export
prune <- function(name = NULL,
                  by = c("auto", "version", "run", "age"),
                  run_id = NULL,
                  keep = NULL,
                  keep_latest = FALSE,
                  older_than = NULL,
                  force = FALSE) {
  by <- match.arg(by)
  if (!is.null(name)) .mr_validate_name(name, context = "prune")

  if (by == "auto" && !is.null(name)) {
    shape <- .mr_lookup_shape(name)
    by <- if (identical(shape, "B")) "run" else "version"
  }

  if (!is.null(name) && by %in% c("version", "run")) {
    shape <- .mr_lookup_shape(name)
    if (by == "version" && identical(shape, "B")) {
      stop(sprintf(
        "prune(): by='version' requires a versioned name; '%s' is an append table. Use by='run' or by='auto'.",
        name), call. = FALSE)
    }
    if (by == "run" && identical(shape, "A")) {
      stop(sprintf(
        "prune(): by='run' requires an append-table name; '%s' is versioned. Use by='version' or by='auto'.",
        name), call. = FALSE)
    }
  }

  if (by == "age") {
    if (is.null(older_than)) {
      stop("prune(): by='age' requires older_than.", call. = FALSE)
    }
    a <- .mr_prune_shape_a(name = name, keep = NULL, keep_latest = FALSE,
                           older_than = older_than, force = force)
    b <- .mr_prune_shape_b(name = name, run_id = NULL, keep = NULL,
                           older_than = older_than, force = force)
    return(invisible(list(versioned = a, append = b)))
  }

  if (by == "auto" && is.null(name)) {
    a <- .mr_prune_shape_a(name = NULL, keep = keep, keep_latest = keep_latest,
                           older_than = older_than, force = force)
    b <- .mr_prune_shape_b(name = NULL, run_id = run_id, keep = keep,
                           older_than = older_than, force = force)
    return(invisible(list(versioned = a, append = b)))
  }

  if (by == "version") {
    return(invisible(.mr_prune_shape_a(
      name = name, keep = keep, keep_latest = keep_latest,
      older_than = older_than, force = force
    )))
  }
  invisible(.mr_prune_shape_b(
    name = name, run_id = run_id, keep = keep,
    older_than = older_than, force = force
  ))
}

## Shape A (versioned) --------------------------------------------------------

.mr_prune_shape_a <- function(name, keep, keep_latest, older_than, force) {
  if (isTRUE(keep_latest) && !is.null(keep)) {
    stop("prune(): pass either `keep_latest` or `keep`, not both.",
         call. = FALSE)
  }
  con <- .mr_get_connection()

  candidates <- if (is.null(name)) {
    DBI::dbGetQuery(con, "SELECT * FROM _mr_versions ORDER BY logical_name, first_seen")
  } else {
    DBI::dbGetQuery(
      con,
      "SELECT * FROM _mr_versions WHERE logical_name = ? ORDER BY first_seen",
      params = list(name)
    )
  }
  if (nrow(candidates) == 0L) {
    return(candidates[0, , drop = FALSE])
  }

  to_prune <- .mr_select_prune_candidates(candidates, keep, keep_latest, older_than)
  if (nrow(to_prune) == 0L) {
    return(to_prune)
  }

  protected <- .mr_protected_version_hashes(con, force = force)
  key <- paste0(to_prune$logical_name, "\x1f", to_prune$content_hash)
  protected_key <- paste0(protected$name, "\x1f", protected$hash)
  keepers <- key %in% protected_key
  if (any(keepers) && !force) {
    warning(sprintf(
      "%d version(s) protected from pruning because they are referenced by run history. Pass force = TRUE to prune them anyway.",
      sum(keepers)
    ), call. = FALSE)
  }
  to_prune <- to_prune[!keepers, , drop = FALSE]
  if (nrow(to_prune) == 0L) {
    return(to_prune)
  }

  for (i in seq_len(nrow(to_prune))) {
    row <- to_prune[i, , drop = FALSE]
    .mr_drop_version(con, row)
  }

  for (nm in unique(to_prune$logical_name)) {
    .mr_refresh_latest_view(con, nm)
  }

  artifact_dir <- file.path(dirname(db_path()), "modelrunnR_artifacts")
  if (dir.exists(artifact_dir) &&
      length(list.files(artifact_dir, all.files = FALSE)) == 0L) {
    unlink(artifact_dir, recursive = TRUE)
  }

  to_prune
}

.mr_select_prune_candidates <- function(candidates, keep, keep_latest, older_than) {
  out <- candidates[FALSE, , drop = FALSE]
  if (nrow(candidates) == 0L) return(out)

  for (nm in unique(candidates$logical_name)) {
    rows <- candidates[candidates$logical_name == nm, , drop = FALSE]
    rows <- rows[order(rows$first_seen, decreasing = FALSE), , drop = FALSE]
    n <- nrow(rows)
    prune_mask <- rep(FALSE, n)

    if (isTRUE(keep_latest)) {
      prune_mask <- prune_mask | (seq_len(n) != n)
    }
    if (!is.null(keep)) {
      k <- as.integer(keep)
      if (k < 0L) stop("prune(): keep must be non-negative.", call. = FALSE)
      prune_mask <- prune_mask | !(seq_len(n) > max(0L, n - k))
    }
    if (!is.null(older_than)) {
      cutoff <- Sys.time() - .mr_parse_duration(older_than, context = "prune")
      prune_mask <- prune_mask | (rows$first_seen < cutoff)
    }

    if (any(prune_mask)) {
      out <- rbind(out, rows[prune_mask, , drop = FALSE])
    }
  }
  out
}

.mr_parse_duration <- function(spec, context = "prune") {
  m <- regmatches(spec, regexec("^([0-9]+)\\s*([smhd])$", spec))[[1]]
  if (length(m) != 3L) {
    stop(sprintf("%s(): could not parse duration '%s'. Use e.g. '30d', '6h', '15m', '45s'.",
                 context, spec), call. = FALSE)
  }
  n <- as.numeric(m[2])
  unit <- m[3]
  seconds <- switch(unit, s = n, m = n * 60, h = n * 3600, d = n * 86400)
  as.difftime(seconds, units = "secs")
}

.mr_protected_version_hashes <- function(con, force = FALSE) {
  empty <- data.frame(name = character(), hash = character(),
                      stringsAsFactors = FALSE)
  if (force) return(empty)

  rows <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE outputs IS NOT NULL AND outputs <> '[]'"
  )
  names_out  <- character()
  hashes_out <- character()
  if (nrow(rows) > 0L) {
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
        nm <- p$name %||% NA_character_
        hs <- p$hash %||% NA_character_
        names_out  <- c(names_out,  nm)
        hashes_out <- c(hashes_out, hs)
      }
    }
  }

  label_rows <- DBI::dbGetQuery(
    con,
    "SELECT outputs FROM _mr_runs WHERE variant_label IS NOT NULL"
  )
  if (nrow(label_rows) > 0L) {
    for (j in seq_len(nrow(label_rows))) {
      raw <- label_rows$outputs[j]
      pairs <- if (is.na(raw) || !nzchar(raw)) {
        list()
      } else {
        tryCatch(
          jsonlite::fromJSON(raw, simplifyVector = FALSE),
          error = function(e) list()
        )
      }
      for (p in pairs) {
        nm <- p$name %||% NA_character_
        hs <- p$hash %||% NA_character_
        names_out  <- c(names_out,  nm)
        hashes_out <- c(hashes_out, hs)
      }
    }
  }

  if (length(names_out) == 0L) return(empty)
  df <- data.frame(name = names_out, hash = hashes_out,
                   stringsAsFactors = FALSE)
  unique(df)
}

.mr_drop_version <- function(con, row) {
  kind <- row$kind[1]
  storage <- row$storage_location[1]

  DBI::dbBegin(con)
  tryCatch({
    if (identical(kind, "table")) {
      .mr_drop_table(con, row$physical_name[1])
    } else if (identical(kind, "artifact")) {
      if (identical(storage, "blob")) {
        DBI::dbExecute(
          con,
          "DELETE FROM _mr_artifacts WHERE physical_name = ?",
          params = list(row$physical_name[1])
        )
      } else if (identical(storage, "file")) {
        if (file.exists(row$physical_name[1]) &&
            !isTRUE(file.remove(row$physical_name[1]))) {
          stop(sprintf("prune(): failed to remove file artifact '%s'",
                       row$physical_name[1]), call. = FALSE)
        }
      }
    }
    DBI::dbExecute(
      con,
      "DELETE FROM _mr_versions WHERE logical_name = ? AND content_hash = ?",
      params = list(row$logical_name[1], row$content_hash[1])
    )
    DBI::dbCommit(con)
  }, error = function(e) {
    DBI::dbRollback(con)
    warning(sprintf(
      "prune(): could not drop '%s' @ %s: %s",
      row$logical_name[1], substr(row$content_hash[1], 1L, 12L),
      conditionMessage(e)
    ), call. = FALSE)
  })
  invisible(NULL)
}

## Shape B (append log) -------------------------------------------------------

.mr_prune_shape_b <- function(name, run_id, keep, older_than, force) {
  con <- .mr_get_connection()

  targets <- if (is.null(name)) {
    DBI::dbGetQuery(con, "SELECT * FROM _mr_append_tables")
  } else {
    DBI::dbGetQuery(con,
      "SELECT * FROM _mr_append_tables WHERE logical_name = ?",
      params = list(name))
  }
  if (nrow(targets) == 0L) {
    return(data.frame(logical_name = character(),
                      rows_pruned  = integer(),
                      stringsAsFactors = FALSE))
  }

  cutoff <- if (!is.null(older_than)) {
    Sys.time() - .mr_parse_duration(older_than, context = "prune")
  } else NULL

  summaries <- vector("list", nrow(targets))
  for (i in seq_len(nrow(targets))) {
    row <- targets[i, , drop = FALSE]
    summaries[[i]] <- .mr_prune_shape_b_one(con, row, run_id, cutoff, keep, force)
  }
  do.call(rbind, summaries)
}

.mr_prune_shape_b_one <- function(con, registry_row, run_id, cutoff, keep, force) {
  logical  <- registry_row$logical_name[1]
  physical <- registry_row$physical_name[1]

  all_runs_sql <- sprintf("SELECT DISTINCT _mr_run_id AS rid FROM %s",
                          .mr_quote_ident(physical))
  all_runs <- DBI::dbGetQuery(con, all_runs_sql)
  if (nrow(all_runs) == 0L) {
    return(data.frame(logical_name = logical, rows_pruned = 0L,
                      stringsAsFactors = FALSE))
  }

  ids_to_prune <- character()
  if (!is.null(run_id)) {
    ids_to_prune <- c(ids_to_prune, as.character(run_id))
  }

  # Stage id lists through a DuckDB temp table rather than inlining as
  # IN (...) literals. For large prune lists the literal form grows
  # SQL body size unboundedly and is slower to parse; the temp-table
  # form keeps each query body constant-size.
  with_id_scope <- function(ids, body) {
    tmp <- paste0("_mr_tmp_prune_ids_",
                  paste(sample(c(0:9, letters), 10, replace = TRUE),
                        collapse = ""))
    DBI::dbWriteTable(
      con, tmp,
      data.frame(id = as.character(ids), stringsAsFactors = FALSE),
      temporary = TRUE, overwrite = TRUE
    )
    on.exit(try(.mr_drop_table(con, tmp), silent = TRUE), add = TRUE)
    body(tmp)
  }

  if (!is.null(cutoff)) {
    rids <- with_id_scope(all_runs$rid, function(tmp) {
      DBI::dbGetQuery(
        con,
        sprintf(
          "SELECT run_id FROM _mr_runs
            WHERE started_at < ? AND run_id IN (SELECT id FROM %s)",
          .mr_quote_ident(tmp)
        ),
        params = list(cutoff)
      )
    })
    ids_to_prune <- c(ids_to_prune, rids$run_id)
  }

  if (!is.null(keep) && is.numeric(keep) && keep >= 0) {
    ranked <- with_id_scope(all_runs$rid, function(tmp) {
      DBI::dbGetQuery(
        con,
        sprintf(
          "SELECT run_id FROM _mr_runs
            WHERE run_id IN (SELECT id FROM %s)
            ORDER BY started_at DESC",
          .mr_quote_ident(tmp)
        )
      )
    })
    if (nrow(ranked) > keep) {
      ids_to_prune <- c(ids_to_prune, ranked$run_id[(keep + 1L):nrow(ranked)])
    }
  }

  ids_to_prune <- unique(ids_to_prune)
  if (length(ids_to_prune) == 0L) {
    return(data.frame(logical_name = logical, rows_pruned = 0L,
                      stringsAsFactors = FALSE))
  }

  if (!isTRUE(force)) {
    labeled <- with_id_scope(ids_to_prune, function(tmp) {
      DBI::dbGetQuery(
        con,
        sprintf(
          "SELECT run_id FROM _mr_runs
            WHERE variant_label IS NOT NULL
              AND run_id IN (SELECT id FROM %s)",
          .mr_quote_ident(tmp)
        )
      )
    })
    ids_to_prune <- setdiff(ids_to_prune, labeled$run_id)
    if (length(labeled$run_id) > 0L) {
      warning(sprintf(
        "%d variant-labeled run(s) protected; pass force = TRUE to prune.",
        length(labeled$run_id)), call. = FALSE)
    }
    if (length(ids_to_prune) == 0L) {
      return(data.frame(logical_name = logical, rows_pruned = 0L,
                        stringsAsFactors = FALSE))
    }
  }

  # Count and DELETE share the same temp table inside one transaction
  # so `row_count` decrements by exactly the number of rows actually
  # removed — a concurrent append between the two can't widen the
  # window.
  count <- with_id_scope(ids_to_prune, function(tmp) {
    DBI::dbBegin(con)
    local_count <- tryCatch({
      c <- DBI::dbGetQuery(
        con,
        sprintf(
          "SELECT COUNT(*) AS c FROM %s WHERE _mr_run_id IN (SELECT id FROM %s)",
          .mr_quote_ident(physical), .mr_quote_ident(tmp)
        )
      )$c[1]
      DBI::dbExecute(
        con,
        sprintf(
          "DELETE FROM %s WHERE _mr_run_id IN (SELECT id FROM %s)",
          .mr_quote_ident(physical), .mr_quote_ident(tmp)
        )
      )
      DBI::dbExecute(
        con,
        "UPDATE _mr_append_tables
            SET row_count = row_count - ?, last_seen = ?
          WHERE logical_name = ?",
        params = list(c, Sys.time(), logical)
      )
      DBI::dbCommit(con)
      c
    }, error = function(e) { DBI::dbRollback(con); stop(e) })
    local_count
  })

  data.frame(logical_name = logical, rows_pruned = as.integer(count),
             stringsAsFactors = FALSE)
}
