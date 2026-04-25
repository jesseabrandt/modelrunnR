#' List labeled variants
#'
#' Returns a data frame of labeled variants known to the active
#' modelrunnR database.
#'
#' @param script Optional script path (absolute or relative — the
#'   function normalizes). If supplied, only variants of that script
#'   are returned.
#' @param name Optional logical name. If supplied, only variants
#'   whose runs produced an output under that name are returned.
#' @return A data frame with columns `script`, `label`, `first_seen`,
#'   `last_seen`, `n_runs`, `latest_run_id`.
#' @export
variants <- function(script = NULL, name = NULL) {
  con <- .mr_get_connection()

  sql <- "
    SELECT
      step                AS script,
      variant_label       AS label,
      MIN(started_at)     AS first_seen,
      MAX(started_at)     AS last_seen,
      COUNT(*)            AS n_runs,
      ARG_MAX(run_id, started_at) AS latest_run_id
    FROM _mr_runs
    WHERE variant_label IS NOT NULL
  "
  params <- list()
  if (!is.null(script)) {
    sql <- paste(sql, "AND step = ?")
    params <- c(params, list(normalizePath(script, mustWork = FALSE)))
  }
  sql <- paste(sql, "GROUP BY step, variant_label ORDER BY last_seen DESC")

  df <- DBI::dbGetQuery(con, sql, params = params)

  if (!is.null(name)) {
    df <- df[.mr_variants_produced(con, df, name), , drop = FALSE]
  }
  df
}

.mr_variants_produced <- function(con, df, name) {
  # For each (script, label) row, check whether any run in that group
  # has an `outputs` JSON entry matching `name`. Returns a logical
  # vector aligned to df.
  if (nrow(df) == 0L) return(logical(0))
  keep <- logical(nrow(df))
  for (i in seq_len(nrow(df))) {
    runs <- DBI::dbGetQuery(
      con,
      "SELECT outputs FROM _mr_runs
        WHERE step = ? AND variant_label = ?",
      params = list(df$script[i], df$label[i])
    )
    for (j in seq_len(nrow(runs))) {
      raw <- runs$outputs[j]
      pairs <- if (is.na(raw) || !nzchar(raw)) {
        list()
      } else {
        tryCatch(
          jsonlite::fromJSON(raw, simplifyVector = FALSE),
          error = function(e) list()
        )
      }
      if (any(vapply(pairs, .mr_output_matches_name, logical(1),
                     name = name))) {
        keep[i] <- TRUE
        break
      }
    }
  }
  keep
}
