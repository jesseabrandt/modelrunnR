# `runs()` — tidy accessor for the run log + `mr_code` print class

**Status:** design, drafted 2026-04-25
**Scope:** Add a `runs()` accessor that returns the contents of `_mr_runs` as an eager tibble, plus an `mr_code` S3 class on the `code_body` column with a `print` method that syntax-highlights via `prettycode`. No schema change. No new entry-point façade (no `inspect()`); `runs()` is the entry point and downstream filtering is dplyr.
**Depends on:** existing `.mr_get_connection()` resolver (R/connection.R:7), existing `_mr_runs` table (R/schema.R:30), `prettycode` (new Imports dependency).

**Non-goals / deferred:**

- No `inspect()` / `summary()` façade. The bare `runs()` call is the entry point; a future "inspect"-style wrapper can be added once a real friction emerges.
- No new accessors for outputs / inputs / session — the JSON columns are surfaced as raw `chr` (see §3); `versions(name)` already covers "who produced X". Per-run output/input/session helpers are out of scope.
- No reformatting of code via `styler`. If stored `deparse()` output becomes a problem, fix it write-side in `launch()`, not read-side here.
- No changes to `launch_code(run_id)` (R/launch_code.R) — different purpose (re-execution, not reading).
- No print methods for `versions()` / `variants()` returns — out of scope.
- No schema change. `_mr_runs.code_body` stays plain `TEXT`; `mr_code` is purely R-side.

## Motivation

The package has two pre-grouped views of runs (`versions(name)` groups by produced artifact, `variants(script, name)` groups by label) but no ungrouped backbone. To answer "what just happened?", "what's in this store?", or "what was the code for run X?", a user today must reach for `DBI::dbGetQuery(con, "SELECT * FROM _mr_runs ...")` — punching through the package abstraction.

`runs()` closes that gap with the smallest possible surface: one new export that returns a tibble, composable with dplyr like every other tidy data frame. No new vocabulary, no façade, no walled garden.

The one piece of that tibble that resists tidy treatment is `code_body`: as a plain `chr` column it shows truncated mid-expression in tibble print, and `pull(code_body)` returns a single string that needs `cat()` to render readably. An `mr_code` class with a `print` method fixes both, without affecting anything stored in DuckDB.

## Target usage

```r
# What's in the store?
runs()
#> # A tibble: 47 × 13
#>   run_id     step          variant_label batch_id  status started_at          duration_ms code_body
#>   <chr>      <chr>         <chr>         <chr>     <chr>  <dttm>                    <int> <mr_code>
#> 1 r_a1b2c3…  fit_model.R   alpha         b_9f2a…   ok     2026-04-25 09:14:02         412 <387 chr>
#> 2 r_d4e5f6…  fit_model.R   beta          b_9f2a…   ok     2026-04-25 09:14:08         389 <391 chr>
#> # …with 5 more columns: code_hash <chr>, inputs <chr>, outputs <chr>,
#> #   session_info <chr>, attached_packages <chr>

# Drill in with dplyr
runs() |> filter(variant_label == "alpha") |> tail(3)

# Read the code for one run (highlighted at a color terminal, plain otherwise)
runs() |> filter(run_id == "r_a1b2c3") |> pull(code_body)
#> mtcars |>
#>   group_by(cyl) |>
#>   summarise(mpg = mean(mpg)) |>
#>   stow("cyl_mpg")
```

## Behavior

### 1. `runs()` signature & semantics

```r
runs <- function() {
  con <- .mr_get_connection()
  out <- DBI::dbReadTable(con, "_mr_runs")
  out <- tibble::as_tibble(out)
  out$code_body <- .mr_as_code(out$code_body)
  out
}
```

- **No arguments.** Connection is resolved via `.mr_get_connection()` (the same options-driven resolver used by `versions()`, `variants()`, `grab()`, `stow()` — see R/connection.R:7).
- **Eager.** Returns a fully materialized `tibble`, matching `versions()` (R/versions.R:21) and `variants()` (R/variants.R:14). `_mr_runs` is metadata, not bulk data; pushing dplyr verbs down to SQL adds complexity for no real gain.
- **All `_mr_runs` columns surfaced.** No subsetting, no renaming, no reordering relative to the table definition. Whatever the schema has, `runs()` returns.
- **`tibble` is a Suggests dep** today; `runs()` requires it. Either promote `tibble` to Imports or use `requireNamespace("tibble", quietly = TRUE)` with a clear error if missing. Recommended: promote to Imports (it's already pulled in transitively via `dbplyr`).

### 2. The `mr_code` class

A class is added to the `code_body` column **on read**, by `runs()`. The DuckDB column itself is unchanged — anyone using `DBI::dbGetQuery(con, "SELECT code_body FROM _mr_runs")` directly gets a plain `character` vector.

```r
.mr_as_code <- function(x) {
  x <- as.character(x)
  class(x) <- c("mr_code", class(x))
  x
}

#' @export
print.mr_code <- function(x, ...) {
  for (i in seq_along(x)) {
    s <- unclass(x)[[i]]
    if (is.na(s) || !nzchar(s)) {
      cat("<no code body>\n")
    } else {
      cat(prettycode::highlight(s), sep = "\n")
    }
    if (i < length(x)) cat("\n")
  }
  invisible(x)
}

#' @export
format.mr_code <- function(x, ...) {
  ifelse(is.na(unclass(x)),
         NA_character_,
         paste0("<", nchar(unclass(x)), " chr>"))
}

#' @export
as.character.mr_code <- function(x, ...) unclass(x)

#' @export
`[.mr_code` <- function(x, i) {
  out <- unclass(x)[i]
  class(out) <- c("mr_code", class(out))
  out
}
```

- **`print`**: writes each element as multi-line code, separated by a blank line if there are several. `prettycode::highlight()` returns a character vector (one element per source line) with ANSI escapes when `crayon::has_color()` is `TRUE`, plain text otherwise. The decision is made by the output sink, not by `interactive()` — so Rscript at a color-capable terminal also gets highlighting, while pipes/files/knitr get plain text.
- **`format`**: returns a short summary like `<412 chr>` for tibble cell display. Without this, the tibble print would dump the whole code block into the cell, breaking the table layout.
- **`as.character`**: strips the class and returns the underlying string, so `paste()`, `gsub()`, `nchar()`, `writeLines()`, etc. work transparently.
- **`[`**: preserves the `mr_code` class on subsetting, so `head(pull(code_body), 1)` and `pull(code_body)[i]` still print as code rather than degrading to plain character.

### 3. JSON-shaped columns stay raw `chr`

`_mr_runs` has four columns whose stored value is a JSON string: `inputs`, `outputs`, `session_info`, `attached_packages`. `runs()` does **not** parse them — they're returned as plain `chr`. Rationale:

- Pre-parsing into list-columns rewards one specific user (someone fluent with `tidyr::unnest`) at the cost of readability for everyone else.
- "Who produced X?" is already answered by `versions(name)` — no need to duplicate it via `runs() |> unnest(outputs) |> filter(...)`.
- Tibble's default print truncates `chr` columns; the cells show as e.g. `[{"name":"cyl_mpg","ha…`. Acceptable and matches how raw DB rows look.
- If a JSON column ever earns its own print class (mirroring `mr_code`), it can be added later without breaking anything.

Users who need the parsed form do `runs() |> mutate(outputs = lapply(outputs, jsonlite::fromJSON))` themselves. Standard R.

### 4. Empty store

If `_mr_runs` exists but has zero rows, `runs()` returns a zero-row tibble with the correct column types — same shape contract as a populated call. `code_body` is still `mr_code`-classed (a zero-length classed vector).

If the store doesn't exist at all (no DB file, no option set), `.mr_get_connection()` already errors with the standard package message — no special handling needed.

### 5. Dependency footprint

- **New Imports: `prettycode`.** Recursive deps: `crayon`, plus base packages (`utils`, `grDevices`, `methods`). Four total. Comparable in weight to existing focused deps (`digest`, `qs2`, `ps`).
- **`tibble` promoted from Suggests to Imports** (already transitive via `dbplyr`).

No `styler`, no `cli`, no further weight.

## Edge cases & tests

| Case | Expected |
|------|----------|
| `runs()` against an empty store (no `_mr_runs` rows) | zero-row tibble, `mr_code`-classed `code_body` |
| `runs()` with no DB option set | error from `.mr_get_connection()` (existing behavior) |
| `pull(code_body)` of single row, color terminal | highlighted multi-line print, no `cat()` needed |
| `pull(code_body)` of single row, sink with no color | plain multi-line print |
| `pull(code_body)` of multiple rows | each printed as a code block, separated by blank lines |
| `pull(code_body)` of a row where `code_body` is `NA` or empty | prints `<no code body>` |
| `runs()` printed at the REPL | tibble shows `<N chr>` in `code_body` cells, layout intact |
| `head(pull(code_body), 1)` | one `mr_code`-classed element, prints as a single code block |
| `as.character(pull(code_body))` | plain `character` vector, no class |
| `paste0(pull(code_body), collapse = "\n")` | works (auto-coerces via `as.character`) |
| `DBI::dbGetQuery(con, "SELECT code_body FROM _mr_runs LIMIT 1")` | plain `character`, no `mr_code` class — DB layer untouched |
| Round-trip: `x <- runs(); identical(as.character(x$code_body), DBI::dbReadTable(con, "_mr_runs")$code_body)` | TRUE |

## Implementation outline

- `R/runs.R` — `runs()` exported, body as in §1.
- `R/mr_code.R` — `.mr_as_code()` (internal), `print.mr_code`, `format.mr_code`, `as.character.mr_code`, `[.mr_code` (all exported via `@export` for S3 dispatch).
- `R/modelrunnR-package.R` — no change needed unless we want to document the class at the package level (probably not).
- `DESCRIPTION` — add `prettycode`, `tibble` to `Imports`.
- `NAMESPACE` — regenerated by `devtools::document()`; should pick up `S3method(print, mr_code)`, `S3method(format, mr_code)`, `S3method(as.character, mr_code)`, and `export(runs)`.
- `tests/testthat/test-runs.R` — covers each row of the table in §"Edge cases & tests".
- `tests/testthat/test-mr-code.R` — covers print method behavior with color forced on/off (use `withr::local_options(crayon.enabled = TRUE/FALSE)`), format method, as.character round-trip.
- `vignettes/getting-started.Rmd` — add a short section showing the three-line usage from §"Target usage".
- `NEWS.md` — entry under the next dev version.

## Open questions

None blocking. Possible follow-ups (not in this spec):

- Sibling accessors for the other tables (`stowed()` listing all names across Shape A + Shape B, `batches()` grouping by `batch_id`) — design when there's a real ask.
- Print method for the JSON columns (`mr_json` class showing `[3 outputs]` instead of truncated string) — same trigger.
- Optional `runs(con = ...)` arg if multi-store workflows become real — currently options-based resolution is sufficient.
