# `runs()` + `mr_code` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an exported `runs()` accessor returning the contents of `_mr_runs` as an eager tibble, plus an `mr_code` S3 class on the `code_body` column with a syntax-highlighting `print` method.

**Architecture:** Two new files (`R/runs.R`, `R/mr_code.R`). `runs()` reads the table via `DBI::dbReadTable`, wraps as tibble, attaches `mr_code` class on `code_body` only. The class lives entirely R-side — DuckDB column stays plain `TEXT`. Print method uses `prettycode::highlight()` (which auto-detects color via `crayon::has_color()`).

**Tech Stack:** R 4.5, DBI, duckdb, tibble, prettycode, testthat.

**Spec:** [`docs/superpowers/specs/2026-04-25-runs-accessor-design.md`](../specs/2026-04-25-runs-accessor-design.md)

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `DESCRIPTION` | modify | Add `prettycode`, `tibble` to `Imports` |
| `R/mr_code.R` | create | `.mr_as_code()` constructor + 4 S3 methods (`print`, `format`, `as.character`, `[`) |
| `R/runs.R` | create | Exported `runs()` function |
| `NAMESPACE` | regenerate | `devtools::document()` picks up `S3method` + `export(runs)` lines |
| `man/runs.Rd`, `man/mr_code.Rd` (or method-specific .Rd files) | regenerate | Roxygen → Rd by `devtools::document()` |
| `tests/testthat/test-mr-code.R` | create | Class-method behavior in isolation |
| `tests/testthat/test-runs.R` | create | Accessor behavior, integration with launch/stow + DB round-trip |
| `NEWS.md` | modify | Entry under the unreleased dev version |
| `vignettes/getting-started.Rmd` | modify | Short "Inspecting runs" subsection demonstrating `runs()` + code printing |

---

### Task 1: Add Imports

**Files:**
- Modify: `DESCRIPTION` (the `Imports:` and `Suggests:` blocks)

- [ ] **Step 1: Edit `DESCRIPTION` to move `tibble` from Suggests to Imports and add `prettycode` to Imports**

The current `Imports:` block (alphabetical) reads:
```
Imports:
    DBI,
    dbplyr,
    digest,
    dplyr,
    duckdb,
    jsonlite,
    ps,
    qs2
```

Change to:
```
Imports:
    DBI,
    dbplyr,
    digest,
    dplyr,
    duckdb,
    jsonlite,
    prettycode,
    ps,
    qs2,
    tibble
```

In the `Suggests:` block, **remove** `tibble,` (it now lives in Imports). The remaining Suggests stays as-is.

- [ ] **Step 2: Verify package still loads**

Run: `Rscript -e 'devtools::load_all()' 2>&1 | tail -5`
Expected: loading message ending in `i Loading modelrunnR`, no errors. (If `prettycode` isn't installed yet, the loader will complain — install with `Rscript -e 'install.packages("prettycode", repos="https://cloud.r-project.org")'` and retry.)

- [ ] **Step 3: Commit**

```bash
git add DESCRIPTION
git commit -m "build(deps): add prettycode + promote tibble to Imports

Required by upcoming runs() accessor and mr_code print class.
prettycode is small (4 recursive deps) and brings syntax-aware
highlighting via crayon-driven sink detection. tibble was already
transitive via dbplyr."
```

---

### Task 2: `mr_code` class — constructor + simple S3 methods

**Files:**
- Create: `R/mr_code.R`
- Create: `tests/testthat/test-mr-code.R`

This task implements the four "easy" pieces (`.mr_as_code`, `format`, `as.character`, `[`) under TDD. The `print` method is in Task 3 because it needs more elaborate test setup.

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-mr-code.R`:

```r
test_that(".mr_as_code attaches mr_code class to character input", {
  x <- .mr_as_code(c("x <- 1", "y <- 2"))
  expect_s3_class(x, "mr_code")
  expect_type(unclass(x), "character")
  expect_equal(unclass(x), c("x <- 1", "y <- 2"))
})

test_that(".mr_as_code preserves NA values and length", {
  x <- .mr_as_code(c("x <- 1", NA_character_, "y <- 2"))
  expect_s3_class(x, "mr_code")
  expect_equal(length(x), 3L)
  expect_true(is.na(unclass(x)[2]))
})

test_that(".mr_as_code on zero-length input yields zero-length mr_code", {
  x <- .mr_as_code(character())
  expect_s3_class(x, "mr_code")
  expect_equal(length(x), 0L)
})

test_that("format.mr_code returns <N chr> for non-NA elements", {
  x <- .mr_as_code(c("abcde", "abcdefghij"))
  expect_equal(format(x), c("<5 chr>", "<10 chr>"))
})

test_that("format.mr_code returns NA for NA elements", {
  x <- .mr_as_code(c("abc", NA_character_))
  out <- format(x)
  expect_equal(out[1], "<3 chr>")
  expect_true(is.na(out[2]))
})

test_that("as.character.mr_code strips the class", {
  raw <- c("x <- 1", "y <- 2")
  x <- .mr_as_code(raw)
  out <- as.character(x)
  expect_identical(out, raw)
  expect_false(inherits(out, "mr_code"))
})

test_that("[.mr_code preserves the class on integer index", {
  x <- .mr_as_code(c("a", "b", "c"))
  expect_s3_class(x[1], "mr_code")
  expect_equal(unclass(x[1]), "a")
})

test_that("[.mr_code preserves the class on logical index", {
  x <- .mr_as_code(c("a", "b", "c"))
  out <- x[c(TRUE, FALSE, TRUE)]
  expect_s3_class(out, "mr_code")
  expect_equal(unclass(out), c("a", "c"))
})

test_that("[.mr_code preserves the class with negative index", {
  x <- .mr_as_code(c("a", "b", "c"))
  expect_s3_class(x[-1], "mr_code")
  expect_equal(unclass(x[-1]), c("b", "c"))
})

test_that("paste0 on mr_code coerces via as.character", {
  x <- .mr_as_code(c("foo", "bar"))
  expect_equal(paste0(x, "!"), c("foo!", "bar!"))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::test(filter = "mr-code")' 2>&1 | tail -20`
Expected: Errors saying `.mr_as_code` and `format.mr_code` etc. are not found (or `could not find function`). Test count > 0, all failing.

- [ ] **Step 3: Create `R/mr_code.R` with the implementation**

```r
#' Internal: attach mr_code class to a character vector
#'
#' Wraps a character vector so that `pull(code_body)` from `runs()` prints
#' as multi-line, syntax-highlighted code rather than a truncated string.
#' The class is purely R-side; the DuckDB column stays plain `TEXT`.
#'
#' @param x A character vector (typically `code_body` straight from
#'   `_mr_runs`). NA elements are preserved.
#' @return The same vector with `"mr_code"` prepended to its class.
#' @keywords internal
#' @noRd
.mr_as_code <- function(x) {
  x <- as.character(x)
  class(x) <- c("mr_code", class(x))
  x
}

#' Print, format, subset, and coerce mr_code vectors
#'
#' `mr_code` is a thin character subclass attached to the `code_body`
#' column of [runs()]. It exists so that pulling the column out of the
#' tibble prints as readable, optionally syntax-highlighted code.
#'
#' @param x An `mr_code` vector.
#' @param i Index passed to `[`.
#' @param ... Unused; present for S3 method signature consistency.
#'
#' @details
#' - `print.mr_code()` writes each element as multi-line code, separating
#'   adjacent elements with a blank line. Syntax highlighting is delegated
#'   to [prettycode::highlight()], which emits ANSI escapes only when
#'   `crayon::has_color()` is `TRUE` — Rscript at a color-capable terminal
#'   gets highlighting; pipes, files, and knitr get plain text.
#' - `format.mr_code()` returns short summaries like `"<412 chr>"` so the
#'   tibble print layout stays compact.
#' - `as.character.mr_code()` strips the class and returns the underlying
#'   strings; standard string ops (`paste`, `gsub`, `nchar`, `writeLines`)
#'   coerce through it transparently.
#' - `[.mr_code` preserves the class on subsetting so
#'   `head(pull(code_body), 1)` still prints as code.
#'
#' @name mr_code
NULL

#' @rdname mr_code
#' @export
format.mr_code <- function(x, ...) {
  raw <- unclass(x)
  ifelse(is.na(raw),
         NA_character_,
         paste0("<", nchar(raw), " chr>"))
}

#' @rdname mr_code
#' @export
as.character.mr_code <- function(x, ...) {
  unclass(x)
}

#' @rdname mr_code
#' @export
`[.mr_code` <- function(x, i) {
  out <- unclass(x)[i]
  class(out) <- c("mr_code", class(out))
  out
}
```

(Note: `print.mr_code` is intentionally omitted here — it's the next task.)

- [ ] **Step 4: Run the four tests that don't need print**

Run: `Rscript -e 'devtools::test(filter = "mr-code")' 2>&1 | tail -25`
Expected: All ten tests above pass. (None of them call `print()` directly.)

- [ ] **Step 5: Commit**

```bash
git add R/mr_code.R tests/testthat/test-mr-code.R
git commit -m "feat(mr_code): add class constructor + format/as.character/[ methods

Internal .mr_as_code() wraps a character vector so the code_body column
of runs() can carry an mr_code class. format() yields '<N chr>' for
compact tibble cell display; as.character() strips back to plain string;
[ preserves the class on subset. Print method follows in next commit."
```

---

### Task 3: `print.mr_code`

**Files:**
- Modify: `R/mr_code.R` (append print method)
- Modify: `tests/testthat/test-mr-code.R` (add print tests)

- [ ] **Step 1: Add the failing tests**

Append to `tests/testthat/test-mr-code.R`:

```r
test_that("print.mr_code emits the code body for a single element", {
  x <- .mr_as_code("x <- 1\ny <- 2")
  out <- capture.output(print(x))
  # Two source lines; we don't pin exact ANSI but expect both to appear.
  joined <- paste(out, collapse = "\n")
  expect_match(joined, "x <- 1", fixed = TRUE)
  expect_match(joined, "y <- 2", fixed = TRUE)
})

test_that("print.mr_code prints '<no code body>' for NA elements", {
  x <- .mr_as_code(NA_character_)
  out <- capture.output(print(x))
  expect_true(any(grepl("<no code body>", out, fixed = TRUE)))
})

test_that("print.mr_code prints '<no code body>' for empty-string elements", {
  x <- .mr_as_code("")
  out <- capture.output(print(x))
  expect_true(any(grepl("<no code body>", out, fixed = TRUE)))
})

test_that("print.mr_code separates multiple elements with a blank line", {
  x <- .mr_as_code(c("a <- 1", "b <- 2"))
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  expect_match(joined, "a <- 1", fixed = TRUE)
  expect_match(joined, "b <- 2", fixed = TRUE)
  # At least one fully blank line between the two code blocks.
  expect_true(any(out == ""))
})

test_that("print.mr_code returns input invisibly", {
  x <- .mr_as_code("x <- 1")
  res <- withVisible(print(x))
  expect_false(res$visible)
  expect_identical(res$value, x)
})

test_that("print.mr_code emits ANSI escapes when crayon color is enabled", {
  withr::local_options(crayon.enabled = TRUE)
  x <- .mr_as_code("x <- 1")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  # ESC = 0x1b. crayon emits CSI sequences like "\033[32m".
  expect_true(grepl("\033\\[", joined))
})

test_that("print.mr_code emits no ANSI escapes when color is disabled", {
  withr::local_options(crayon.enabled = FALSE)
  x <- .mr_as_code("x <- 1")
  out <- capture.output(print(x))
  joined <- paste(out, collapse = "\n")
  expect_false(grepl("\033\\[", joined))
})

test_that("print.mr_code highlights every line of multi-line code (not just the first)", {
  withr::local_options(crayon.enabled = TRUE)
  x <- .mr_as_code("x <- 1\ny <- 2")
  out <- capture.output(print(x))
  # Both '<-' tokens should be wrapped in ANSI escapes when highlighting works
  # line-by-line. If only the first line were highlighted, the second '<-'
  # would appear without escape codes.
  joined <- paste(out, collapse = "\n")
  n_arrows_with_color <- length(gregexpr("\033\\[\\d+m<-", joined)[[1]])
  expect_gte(n_arrows_with_color, 2L)
})
```

- [ ] **Step 2: Run print tests to verify they fail**

Run: `Rscript -e 'devtools::test(filter = "mr-code")' 2>&1 | tail -25`
Expected: The seven new tests fail with `could not find function "print.mr_code"` or fall through to `print.default`. Earlier tests still pass.

- [ ] **Step 3: Append `print.mr_code` to `R/mr_code.R`**

Add at the end of the file:

```r
#' @rdname mr_code
#' @export
print.mr_code <- function(x, ...) {
  raw <- unclass(x)
  for (i in seq_along(raw)) {
    s <- raw[[i]]
    if (is.na(s) || !nzchar(s)) {
      cat("<no code body>\n")
    } else {
      # prettycode::highlight() treats each vector element as one source line.
      # Splitting first ensures every line is colored (a single multi-line
      # string would only get the first line highlighted).
      lines <- strsplit(s, "\n", fixed = TRUE)[[1]]
      cat(prettycode::highlight(lines), sep = "\n")
      cat("\n")
    }
    if (i < length(raw)) cat("\n")
  }
  invisible(x)
}
```

- [ ] **Step 4: Run all mr-code tests**

Run: `Rscript -e 'devtools::test(filter = "mr-code")' 2>&1 | tail -25`
Expected: All seventeen tests (ten from Task 2 + seven new) pass.

- [ ] **Step 5: Commit**

```bash
git add R/mr_code.R tests/testthat/test-mr-code.R
git commit -m "feat(mr_code): add print method with prettycode highlighting

Splits the stored code_body on \\n before passing to
prettycode::highlight() so every source line gets colored, not just the
first. Color decision is made by crayon::has_color() — interactive
sessions and color-capable Rscript terminals get ANSI; pipes, files,
and knitr stay plain. NA / empty-string rows print '<no code body>'."
```

---

### Task 4: `runs()` accessor

**Files:**
- Create: `R/runs.R`
- Create: `tests/testthat/test-runs.R`

- [ ] **Step 1: Write the failing tests**

Create `tests/testthat/test-runs.R`:

```r
test_that("runs() against an empty store returns a zero-row tibble with mr_code on code_body", {
  new_test_db()

  out <- runs()
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 0L)
  expect_true("code_body" %in% names(out))
  expect_s3_class(out$code_body, "mr_code")
})

test_that("runs() returns a tibble after launch() populates _mr_runs", {
  new_test_db()

  launch({ stow(data.frame(x = 1:3), "out_a") })
  launch({ stow(data.frame(x = 4:6), "out_b") })

  out <- runs()
  expect_s3_class(out, "tbl_df")
  expect_equal(nrow(out), 2L)
  expect_true(all(c("run_id", "step", "code_body", "started_at", "status") %in% names(out)))
})

test_that("runs()$code_body has class mr_code", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  out <- runs()
  expect_s3_class(out$code_body, "mr_code")
})

test_that("pull(code_body) yields an mr_code-classed character", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  body <- dplyr::pull(runs(), code_body)
  expect_s3_class(body, "mr_code")
  expect_type(unclass(body), "character")
  expect_equal(length(body), 1L)
})

test_that("DBI::dbReadTable on _mr_runs still returns a plain character (DB unchanged)", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  con <- .mr_get_connection()
  raw <- DBI::dbReadTable(con, "_mr_runs")
  expect_type(raw$code_body, "character")
  expect_false(inherits(raw$code_body, "mr_code"))
})

test_that("runs() round-trips code_body identically to dbReadTable (modulo class)", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out_a") })
  launch({ stow(data.frame(x = 2), "out_b") })

  con <- .mr_get_connection()
  raw <- DBI::dbReadTable(con, "_mr_runs")
  out <- runs()

  # Same row order is not guaranteed; sort both by run_id before comparing.
  raw_sorted <- raw[order(raw$run_id), , drop = FALSE]
  out_sorted <- out[order(out$run_id), , drop = FALSE]

  expect_identical(as.character(out_sorted$code_body), raw_sorted$code_body)
})

test_that("runs() surfaces all _mr_runs columns (no subsetting)", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  con <- .mr_get_connection()
  schema_cols <- DBI::dbListFields(con, "_mr_runs")
  expect_setequal(names(runs()), schema_cols)
})

test_that("JSON-shaped columns stay raw character", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") })

  out <- runs()
  for (col in c("inputs", "outputs", "session_info", "attached_packages")) {
    if (col %in% names(out)) {
      expect_type(out[[col]], "character")
      expect_false(inherits(out[[col]], "mr_code"))
    }
  }
})

test_that("runs() with no DB option set errors via .mr_get_connection", {
  withr::local_options(list(modelrunnR.db = NULL))
  .mr_reset_connection()
  expect_error(runs())
})

test_that("downstream dplyr filter on runs() works as expected", {
  new_test_db()
  launch({ stow(data.frame(x = 1), "out") }, label = "alpha")
  launch({ stow(data.frame(x = 2), "out") }, label = "beta")

  filtered <- dplyr::filter(runs(), variant_label == "alpha")
  expect_equal(nrow(filtered), 1L)
  expect_s3_class(filtered$code_body, "mr_code")  # class survives dplyr
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::test(filter = "^runs$")' 2>&1 | tail -25`
Expected: All ten tests fail with `could not find function "runs"`.

- [ ] **Step 3: Create `R/runs.R`**

```r
#' List runs recorded in the modelrunnR store
#'
#' Returns the contents of `_mr_runs` as an eager tibble — one row per
#' run, all schema columns surfaced unmodified except that `code_body`
#' carries an [mr_code] class so that `dplyr::pull(code_body)` prints as
#' readable, syntax-highlighted code.
#'
#' This is the tidy backbone for inspecting the store. Filtering,
#' grouping, and counting are done with dplyr verbs on the returned
#' tibble — no new vocabulary. JSON-shaped columns (`inputs`, `outputs`,
#' `session_info`, `attached_packages`) are returned as plain character;
#' parse on demand with [jsonlite::fromJSON()].
#'
#' The connection is resolved via [getOption()] `"modelrunnR.db"`, the
#' same mechanism used by [versions()], [variants()], [grab()], and
#' [stow()]. There is no `con` argument by design.
#'
#' @return A tibble with all `_mr_runs` columns. `code_body` has class
#'   `c("mr_code", "character")`; all other columns are their natural
#'   types. Returns a zero-row tibble with the correct column types if
#'   the table exists but is empty.
#'
#' @seealso [versions()] for the produced-artifact view, [variants()]
#'   for the labeled-pipeline view, [launch_code()] to retrieve a
#'   single run's code as a plain string for re-execution.
#'
#' @examples
#' \dontrun{
#'   # What just happened?
#'   runs() |> tail(5)
#'
#'   # Read the code from one run
#'   runs() |>
#'     dplyr::filter(run_id == "run_20260425_143010_a4f9b2") |>
#'     dplyr::pull(code_body)
#' }
#' @export
runs <- function() {
  con <- .mr_get_connection()
  out <- DBI::dbReadTable(con, "_mr_runs")
  out <- tibble::as_tibble(out)
  out$code_body <- .mr_as_code(out$code_body)
  out
}
```

- [ ] **Step 4: Run runs tests to verify they pass**

Run: `Rscript -e 'devtools::test(filter = "^runs$")' 2>&1 | tail -25`
Expected: All ten tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/runs.R tests/testthat/test-runs.R
git commit -m "feat(runs): export runs() — tidy accessor for _mr_runs

Returns the run log as an eager tibble. Connection resolved via the
existing options-driven .mr_get_connection() — no con argument, matches
versions()/variants()/grab() house style. The code_body column carries
the mr_code class so pull(code_body) prints as readable, optionally
syntax-highlighted code. JSON-shaped columns (inputs, outputs, etc.)
are surfaced as plain chr — users parse on demand."
```

---

### Task 5: Regenerate documentation + NAMESPACE

**Files:**
- Modify: `NAMESPACE` (auto-regenerated)
- Modify: `man/*.Rd` (auto-regenerated)

- [ ] **Step 1: Run document()**

Run: `Rscript -e 'devtools::document()' 2>&1 | tail -20`
Expected: Lines like `Writing NAMESPACE`, `Writing runs.Rd`, `Writing mr_code.Rd`. No errors.

- [ ] **Step 2: Verify NAMESPACE has the expected entries**

Run: `grep -E "(^export\\(runs\\)|S3method\\((print|format|as\\.character|\\[), mr_code\\))" NAMESPACE`

Expected output (order may differ, exact lines):
```
S3method("[",mr_code)
S3method(as.character,mr_code)
S3method(format,mr_code)
S3method(print,mr_code)
export(runs)
```

If any line is missing, the corresponding `@export` tag in `R/mr_code.R` or `R/runs.R` is missing. Fix and re-run document().

- [ ] **Step 3: Run the full test suite to confirm nothing else broke**

Run: `Rscript -e 'devtools::test()' 2>&1 | tail -5`
Expected: A line like `[ FAIL 0 | WARN <n> | SKIP 0 | PASS <N> ]`. No failures. PASS count is the previous baseline (615) plus the new tests (~27).

- [ ] **Step 4: Commit**

```bash
git add NAMESPACE man/
git commit -m "docs: regenerate NAMESPACE + Rd files for runs() + mr_code"
```

---

### Task 6: NEWS entry

**Files:**
- Modify: `NEWS.md`

- [ ] **Step 1: Edit `NEWS.md` — add a "New features" item under the existing dev-version heading**

Open `NEWS.md`. Under the existing `# modelrunnR 0.0.0.9000` heading, find the `## New features` section. Add a new bullet (alphabetical or chronological — match the surrounding style; if unsure, append to the end of the list):

```markdown
* `runs()` — tidy accessor returning the contents of `_mr_runs` as
  an eager tibble. The `code_body` column carries an `mr_code` class
  so `dplyr::pull(code_body)` prints as readable, optionally
  syntax-highlighted code (via `prettycode`). JSON-shaped columns
  (`inputs`, `outputs`, `session_info`, `attached_packages`) are
  surfaced as plain `chr`; parse on demand with `jsonlite::fromJSON()`.
  No schema change — the `mr_code` class is purely R-side, so direct
  `DBI::dbGetQuery()` against `_mr_runs` is unaffected. See
  `docs/superpowers/specs/2026-04-25-runs-accessor-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add NEWS.md
git commit -m "docs(NEWS): announce runs() + mr_code class"
```

---

### Task 7: Vignette section

**Files:**
- Modify: `vignettes/getting-started.Rmd`

- [ ] **Step 1: Identify the right insertion point**

Read `vignettes/getting-started.Rmd` to find where existing accessors are demonstrated (likely near the `versions()` / `variants()` examples — search for `versions(` or `variants(` in the vignette). The new section should land near them as part of the "inspecting" story.

- [ ] **Step 2: Add a subsection**

Insert a new subsection (use the heading depth that matches sibling subsections — typically `##` if the file uses `#` for top-level). Example content:

````markdown
## Inspecting runs

`runs()` returns the run log as a tibble — one row per run, all
recorded columns surfaced. Drill in with dplyr.

```{r runs-inspect, eval=FALSE}
runs()

runs() |> dplyr::filter(variant_label == "alpha") |> tail(3)
```

The `code_body` column carries an `mr_code` class. Pulling it out
prints as multi-line code (syntax-highlighted at a color-capable
terminal):

```{r runs-code, eval=FALSE}
runs() |>
  dplyr::filter(run_id == "run_20260425_143010_a4f9b2") |>
  dplyr::pull(code_body)
```

The class is purely R-side: `DBI::dbGetQuery()` against `_mr_runs`
returns plain character, so the store stays usable without the
package.
````

(Use `eval=FALSE` if other accessor chunks in the vignette also use it; otherwise mirror their `eval=TRUE` setup with a `new_test_db()` + `launch()` preamble.)

- [ ] **Step 3: Verify the vignette parses (knitr can tokenize the chunks)**

Run: `Rscript -e 'rmarkdown::render("vignettes/getting-started.Rmd", quiet = TRUE)' 2>&1 | tail -10`
Expected: Output ends with a successful render (no `Quitting from lines...` errors). If the chunks need `library(modelrunnR)` or any specific setup that isn't already in the vignette preamble, copy the pattern from the surrounding subsections.

- [ ] **Step 4: Commit**

```bash
git add vignettes/getting-started.Rmd
git commit -m "docs(vignette): add 'Inspecting runs' subsection demonstrating runs()"
```

---

### Task 8: Final verification

**Files:** none modified

- [ ] **Step 1: Re-run the full test suite**

Run: `Rscript -e 'devtools::test()' 2>&1 | tail -5`
Expected: `[ FAIL 0 | WARN <n> | SKIP 0 | PASS <N> ]`. No failures. PASS count is at least the previous baseline + the new tests.

- [ ] **Step 2: Run R CMD check (lightweight)**

Run: `Rscript -e 'devtools::check(args = c("--no-manual", "--no-build-vignettes"), error_on = "error")' 2>&1 | tail -30`
Expected: Output ends with `0 errors | 0 warnings | <n> notes`. Notes about new Imports (`prettycode`, `tibble`) being unused are fine if any appear — the implementation actually uses them, so this shouldn't fire.

- [ ] **Step 3: Verify the manual smoke test**

Run:
```bash
Rscript -e '
devtools::load_all()
withr::local_options(modelrunnR.db = tempfile(fileext = ".duckdb"))
.mr_reset_connection()
launch({ stow(data.frame(x = 1:3), "demo") })
print(runs())
cat("\n--- pull(code_body) ---\n")
print(dplyr::pull(runs(), code_body))
' 2>&1 | tail -25
```
Expected: A tibble print followed by the highlighted (or plain) `code_body` text. If interactive ANSI escapes garble the output here, that's expected — what matters is that the code is fully visible and no errors are raised.

- [ ] **Step 4: No commit needed** (verification only)

---

## Self-Review Notes

- **Spec coverage:**
  - §1 `runs()` signature & semantics → Task 4
  - §2 `mr_code` class (constructor + 4 methods) → Tasks 2 + 3
  - §3 JSON columns stay `chr` → covered by `tests/testthat/test-runs.R` "JSON-shaped columns stay raw character"
  - §4 Empty store → covered by "runs() against an empty store returns a zero-row tibble"
  - §5 Dependency footprint → Task 1
  - Edge cases table → mapped onto the test cases in Tasks 2/3/4 (empty store, NA/empty body, head subsetting, color on/off, multi-line highlighting, DB-layer untouched, round-trip identity)
- **No placeholders.** All code blocks are complete. All bash commands have explicit expected output.
- **Type consistency.** `mr_code` is the only new class. `.mr_as_code()` is internal (`.` prefix), not exported. `runs()` is the only new exported function. Method names match the spec: `print.mr_code`, `format.mr_code`, `as.character.mr_code`, `[.mr_code`.
