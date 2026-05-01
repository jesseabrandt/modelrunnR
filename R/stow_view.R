## View-shape stow: dbplyr lazy expression -> CREATE OR REPLACE VIEW.
##
## Hashing follows the precedent set by .mr_register_view() in
## launch_sql.R: the rendered SQL text is the content_hash input. View
## identity therefore drifts when (a) the user changes the lazy
## expression or (b) an upstream input's physical name drifts (which
## happens for versioned-shape inputs but not for append-shape inputs).
## See TODO.md "Surfaced 2026-05-01" for the staleness weak spot on
## append-shape sources.

# Scan a rendered SQL string for tokens that match physical names
# registered in `_mr_versions` or `_mr_append_tables`. Returns a list
# of (name, hash) pairs. Errors if no managed names are found ("strict"
# input resolution: a view-stow with no upstream provenance is almost
# certainly a user mistake).
#
# Detection is lexical -- tokenizes on word characters and matches
# against the registries. The two registries have disjoint physical-
# name conventions (`name__hex_hash` for versioned, `name__append` for
# append) so a token can only match one or the other. False positives
# would require a user to have a string literal in the SQL whose value
# coincides with a physical name; unlikely but acknowledged.
.mr_sniff_view_inputs <- function(con, rendered_sql) {
  tokens <- unique(regmatches(
    rendered_sql,
    gregexpr("[A-Za-z_][A-Za-z_0-9]*", rendered_sql)
  )[[1]])
  if (length(tokens) == 0L) {
    stop(
      "stow(shape = 'view'): no modelrunnR-managed inputs found in expression. ",
      "Lazy expressions for view-stow must derive from grab().",
      call. = FALSE
    )
  }

  # Render the IN-list inline. DuckDB has issues with vector-bound IN
  # via DBI parameterization in some versions; quote each token defensively.
  quote_str <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
  in_list <- paste(vapply(tokens, quote_str, character(1)), collapse = ", ")

  versioned <- DBI::dbGetQuery(con, sprintf(
    "SELECT physical_name, logical_name, content_hash
       FROM _mr_versions
      WHERE physical_name IN (%s)", in_list
  ))
  appended <- DBI::dbGetQuery(con, sprintf(
    "SELECT physical_name, logical_name
       FROM _mr_append_tables
      WHERE physical_name IN (%s)", in_list
  ))

  if (nrow(versioned) + nrow(appended) == 0L) {
    stop(
      "stow(shape = 'view'): no modelrunnR-managed inputs found in expression. ",
      "Lazy expressions for view-stow must derive from grab().",
      call. = FALSE
    )
  }

  inputs <- vector("list", nrow(versioned) + nrow(appended))
  i <- 1L
  for (j in seq_len(nrow(versioned))) {
    inputs[[i]] <- list(
      name = versioned$logical_name[j],
      hash = versioned$content_hash[j]
    )
    i <- i + 1L
  }
  for (j in seq_len(nrow(appended))) {
    inputs[[i]] <- list(
      name = appended$logical_name[j],
      hash = NA_character_
    )
    i <- i + 1L
  }
  inputs
}
