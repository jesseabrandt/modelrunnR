# Rename `launch(script_path = …)` → `launch(code = …)` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the first argument of `launch()` from `script_path` to `code`, since the argument accepts R code (file path, braced block, `mr_label()`, or `mr_sql()`) — not only a script path. Preserve callers who passed the name explicitly via a soft deprecation shim that warns and forwards the value.

**Architecture:** Single-file rename in `R/launch.R`. The shim lifts the argument-capture logic out of `substitute(script_path)` (currently at line 159) and hoists it to the top of the body, where it picks between two sources:

- Normal path → `script_expr <- substitute(code)`, `code` already holds the value via R's formal-arg binding.
- Deprecated path → `script_expr <- match.call()[["script_path"]]`, `code <- list(...)$script_path`.

This keeps inline-mode dispatch (`is.call(script_expr) && script_expr[[1]] == "{"`) working under both names, including braced-block arguments passed via the deprecated name. No `base R` call-rewriting/re-dispatch is needed, and no new package dependency is introduced — a plain `warning()` suffices per CLAUDE.md's lean-imports rule.

**Tech Stack:** R 4.5, `devtools`, `testthat` 3e.

**Scope boundaries:**

- `R/launch.R`, `man/launch.Rd` (regenerated), user-facing docs (`docs/api-reference.md`, `docs/design.md`), `NEWS.md`, and a new test file.
- **Not in scope:** `R/hash_code.R` (its `script_path` parameter is genuinely a path, internal). Historical plans/specs under `docs/superpowers/plans/` and `docs/plan.md` are left as-is. Vignettes and existing tests use positional `launch(...)` calls and need no change (verified by grep — no `script_path =` references in `tests/` or `vignettes/`).

---

### Task 1: Add failing tests for the deprecation shim

**Files:**
- Create: `tests/testthat/test-launch-deprecated-args.R`

- [ ] **Step 1: Write the failing tests**

```r
# tests/testthat/test-launch-deprecated-args.R

test_that("launch() warns when `script_path` is passed by name and still runs", {
  setup <- .mr_test_setup()
  on.exit(.mr_test_teardown(setup), add = TRUE)

  script <- file.path(setup$tmp, "prep.R")
  writeLines('stow(data.frame(a = 1), "x")', script)

  expect_warning(
    run <- launch(script_path = script),
    "`script_path` is deprecated"
  )
  expect_equal(run$status, "ok")
})

test_that("launch() accepts `code = ` as the new argument name", {
  setup <- .mr_test_setup()
  on.exit(.mr_test_teardown(setup), add = TRUE)

  script <- file.path(setup$tmp, "prep.R")
  writeLines('stow(data.frame(a = 1), "x")', script)

  run <- launch(code = script)
  expect_equal(run$status, "ok")
})

test_that("launch() errors if both `code` and `script_path` are passed", {
  setup <- .mr_test_setup()
  on.exit(.mr_test_teardown(setup), add = TRUE)

  script <- file.path(setup$tmp, "prep.R")
  writeLines('stow(data.frame(a = 1), "x")', script)

  expect_error(
    launch(code = script, script_path = script),
    "pass `code` only"
  )
})

test_that("launch(script_path = { ... }) still dispatches to inline mode", {
  setup <- .mr_test_setup()
  on.exit(.mr_test_teardown(setup), add = TRUE)

  suppressWarnings({
    run <- launch(script_path = {
      stow(data.frame(a = 1), "x")
    })
  })
  expect_equal(run$status, "ok")
  expect_true(startsWith(run$step, "<inline:"))
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-launch-deprecated-args.R")'`
Expected: all four tests fail — `code` argument not recognized; `script_path = ...` still binds to the old formal arg with no warning.

### Task 2: Hoist argument capture and add the shim

**Files:**
- Modify: `R/launch.R` (signature at line 112, body starting line 114)

- [ ] **Step 1: Rename the formal parameter in the signature**

Change line 112:

```r
launch <- function(code, rebind = NULL, label = NULL, external_inputs = NULL,
                   force = FALSE, duckdb_seed = NULL, materialize = FALSE,
                   on_error = "raise", ...) {
```

- [ ] **Step 2: Hoist expression capture to the top of the body**

Current code at line 115 and line 159:

```r
  dots <- list(...)
  if ("pin" %in% names(dots) || "data" %in% names(dots)) {
    ...
  }
  ...
  script_expr <- substitute(script_path)
```

Replace the top of the body with:

```r
  dots <- list(...)

  # Deprecation shim for the old `script_path = ` name. Captured here,
  # before anything else touches `code`, so substitute()-style
  # semantics (inline-mode { ... } detection) work under both names.
  if ("script_path" %in% names(dots)) {
    if (!missing(code)) {
      stop(
        "launch(): `script_path` is deprecated; pass `code` only (not both).",
        call. = FALSE
      )
    }
    warning(
      "launch(): `script_path` is deprecated; use `code` instead. ",
      "The argument accepts a braced block, a file path, mr_label(), or ",
      "mr_sql() -- not only a script path.",
      call. = FALSE
    )
    mcall <- match.call()
    script_expr <- mcall[["script_path"]]
    code <- dots$script_path
    dots$script_path <- NULL
  } else {
    script_expr <- substitute(code)
  }

  if ("pin" %in% names(dots) || "data" %in% names(dots)) {
    stop(
      "launch(): `pin` and `data` were removed in the swappability rework. ",
      "Use `rebind = list(...)`: bare R values replace `data`, ",
      "and mr_hash()/mr_run() replace `pin`. See docs/design.md ",
      "section 'Variants and swappability'.",
      call. = FALSE
    )
  }
  if (length(dots) > 0) {
    stop(sprintf("launch(): unknown arguments: %s",
                 paste(names(dots), collapse = ", ")),
         call. = FALSE)
  }
```

- [ ] **Step 3: Delete the original `script_expr <- substitute(script_path)` line**

The old assignment (currently at line 159) is now redundant — `script_expr` is populated by the shim above. Remove that line plus its comment block (lines 156–159).

- [ ] **Step 4: Rename remaining `script_path` references in the body**

Use `replace_all` with `old_string = "script_path"`, `new_string = "code"` in `R/launch.R`. Verify by grep that only the roxygen `@param` comment and body references are affected; the string `"script_path"` in the shim's detection logic and warning message stays literal.

Actually: the `"script_path"` in `names(dots)` and the warning text must remain literal strings — `replace_all` would change them. Instead, do targeted edits at each call site in the body. The affected lines (pre-rename) are: 159, 168, 170, 171, 172, 177, 224, 225, 228, 242, 247, 250, 251, 252, 254, 255, 258, 261.

After the hoist in Step 2, `substitute(code)` is gone; remaining sites reference the value `script_path`, which becomes `code`. The "script not found" error string at line 255 also changes to describe the concept better:

```r
stop(sprintf("launch(): file not found: %s", code), call. = FALSE)
```

- [ ] **Step 5: Update the roxygen `@param` at lines 51–54**

Replace the current multi-line param block with:

```r
#' @param code The code modelrunnR should run. One of:
#'   - a braced `{ ... }` block (inline R) -- dispatch is by syntax;
#'     a literal `{ ... }` in the call triggers inline mode.
#'   - a path to an `.R` script (R file mode).
#'   - a path to a `.sql` file, or [mr_sql()] (SQL mode).
#'   - [mr_label()] (relaunch mode -- re-executes the most recent run
#'     under that label).
```

### Task 3: Regenerate man page and run the full test suite

- [ ] **Step 1: Regenerate `man/launch.Rd`**

Run: `Rscript -e 'devtools::document()'`
Expected: `man/launch.Rd` updates to reference `code`; no other `.Rd` files change.

- [ ] **Step 2: Run the deprecation tests**

Run: `Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-launch-deprecated-args.R")'`
Expected: all four tests pass.

- [ ] **Step 3: Run the full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: all existing tests pass. No existing test uses `script_path =` by name (confirmed by grep of `tests/testthat/`), so positional callers are unaffected.

### Task 4: Update user-facing documentation

**Files:**
- Modify: `docs/api-reference.md:62`
- Modify: `docs/design.md:111,144`

- [ ] **Step 1: Update `docs/api-reference.md` line 62**

```
launch(code,                        # braced block, file path, mr_label(), or mr_sql()
       rebind = NULL,               # named list; see §5
       label = NULL,                # variant label
       external_inputs = NULL,      # list(files = chr, env = chr)
       force = FALSE,               # force run even if fresh
       ...)                         # reserved; traps removed pin=/data= and deprecated script_path=
```

- [ ] **Step 2: Update `docs/design.md` line 111**

Change `**`launch(script_path, rebind = NULL, label = NULL, external_inputs = NULL)`**` to `**`launch(code, rebind = NULL, label = NULL, external_inputs = NULL)`**` and replace "Sources `script_path` in an instrumented context" with "Runs `code` in an instrumented context (a file path, a braced block, a SQL ref, or a relaunch label)".

- [ ] **Step 3: Update `docs/design.md` line 144**

Change `When \`launch(script_path, rebind = NULL, label = NULL)\` is called:` to `When \`launch(code, rebind = NULL, label = NULL)\` is called:`

### Task 5: Update NEWS.md

**Files:**
- Modify: `NEWS.md`

- [ ] **Step 1: Add a bullet near the top of the in-development section**

```markdown
* **`launch()` first argument renamed from `script_path` to `code`.** The
  argument accepts a braced block, a file path, `mr_label()`, or
  `mr_sql()` — not only a script path, so the name now reflects the
  contract. Callers that passed `script_path = ...` by name continue to
  work with a deprecation warning; positional callers (`launch("fit.R")`)
  are unaffected.
```

### Task 6: Commit

- [ ] **Step 1: Stage and commit**

```bash
git add R/launch.R man/launch.Rd tests/testthat/test-launch-deprecated-args.R \
        docs/api-reference.md docs/design.md NEWS.md \
        docs/superpowers/plans/2026-04-21-rename-script-path-to-code.md
git commit -m "refactor(launch): rename script_path to code with deprecation shim

The first argument of launch() accepts a braced block, a file path,
mr_label(), or mr_sql() — not only a script path. Rename for honesty;
keep script_path working via a warning and expression-preserving
argument capture at the top of the body."
```
