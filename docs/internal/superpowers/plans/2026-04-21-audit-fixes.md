# Audit-Fix Plan for the `script_path` → `code` Rename

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the 11 audit findings from the code/readability/security review of the `script_path` → `code` rename. Triage is captured below.

**Architecture:** All changes are localized to the five files already touched by the rename. Edits are grouped by file to minimize context switching. No new code paths, no new dependencies.

**Tech Stack:** R 4.5, `testthat` 3e, `devtools`, plain Markdown.

## Triage

| # | Severity | Decision | Reason |
|---|----------|----------|--------|
| 1 | warning | **apply** | Real edge-case correctness bug in the shim |
| 2 | warning | **apply** | NEWS section split is confusing; "Deprecations" is conventional |
| 3 | warning | **apply** | `@param ...` doc is now incomplete |
| 4 | warning | **apply** | `api-reference.md` dispatch list is internally inconsistent |
| 5 | suggestion | **apply** | Trivial; tightens the prose |
| 6 | suggestion | **apply** | Trivial; one bullet |
| 7 | suggestion | **apply** | One extra test; locks shim responsibility cheaply |
| 8 | suggestion | **apply** | One extra assertion; directly tests the invariant the shim preserves |
| 9 | suggestion | **skip** | Reviewer flagged as optional/belt-and-suspenders; not worth `withCallingHandlers` machinery for a soft deprecation that will be removed. YAGNI. |
| 10 | suggestion | **apply** | One sentence; makes design.md scope-coherent |
| 11 | suggestion | **apply** | One sentence; sets expectations for deprecation timeline |

## File-grouped task list

### Task 1: Fix `R/launch.R` — findings 1, 3, 5, 6

**Files:**
- Modify: `R/launch.R`

- [ ] **Step 1: Finding 1 — strip all `script_path` entries from `dots`**

At line 139 (inside the shim), replace:
```r
dots$script_path <- NULL
```
with:
```r
dots[names(dots) == "script_path"] <- NULL
```

- [ ] **Step 2: Finding 3 — extend `@param ...` to mention the deprecated alias**

Update the `@param ...` block (around line 110):
```r
#' @param ... Reserved for future arguments. Also traps legacy arguments:
#'   `pin` / `data` from before the swappability rework (error), and the
#'   deprecated `script_path` alias for `code` (deprecation warning).
```

- [ ] **Step 3: Finding 5 — shorten the duplicated shim-rationale comment**

The comment block at lines 120–122 and the comment block at lines 184–187 both explain the "capture before touching `code`" rationale. Keep the thorough version at the dispatch site (lines 184–187, where `script_expr` is read) and shorten the shim-site comment (lines 120–122) to one line:
```r
# Deprecation shim for the old `script_path = ` name. See the dispatch
# block below for why the capture must happen here.
```

- [ ] **Step 4: Finding 6 — tighten `@param code` bullet phrasing**

In the `@param code` block (lines 51–57), replace the first bullet:
```
#'   - a braced `{ ... }` block (inline R) -- dispatch is by syntax;
#'     a literal `{ ... }` in the call triggers inline mode.
```
with the simpler:
```
#'   - a braced `{ ... }` block (inline R) -- a literal `{ ... }` at
#'     the call site triggers inline mode.
```

### Task 2: Fix `NEWS.md` — findings 2, 11

**Files:**
- Modify: `NEWS.md`

- [ ] **Step 1: Rename the section heading**

Change `## Breaking-ish changes` to `## Deprecations`.

- [ ] **Step 2: Add the removal-timeline sentence**

Append to the end of the bullet under `## Deprecations`:
```
The alias will be removed in a future release; migrate named calls to `code = ...`.
```

### Task 3: Fix `docs/api-reference.md` — finding 4

**Files:**
- Modify: `docs/api-reference.md`

- [ ] **Step 1: Add a SQL dispatch item**

Under the numbered dispatch list (items 1–3 after the signature block in §3.2), add a new item between the current #2 (`mr_label`) and #3 (file path):
```
3. First arg is `mr_sql(x)` (inline SQL) or has a `.sql` extension (file SQL) → **SQL mode**. See §3.6.
```
Renumber the existing file-path item from 3 to 4.

### Task 4: Fix `docs/design.md` — finding 10

**Files:**
- Modify: `docs/design.md`

- [ ] **Step 1: Add a scope-clarifier sentence above the numbered flow**

Right before the numbered list at line 146 (i.e., just after the line that says `When launch(code, rebind = NULL, label = NULL) is called:`), insert:
```
The canonical flow below assumes file-mode R; inline, relaunch, and SQL modes dispatch through the same recording context with mode-specific variations at steps 1 and 5.
```

### Task 5: Fix `tests/testthat/test-launch-deprecated-args.R` — findings 7, 8

**Files:**
- Modify: `tests/testthat/test-launch-deprecated-args.R`

- [ ] **Step 1: Finding 7 — add test that shim strips before unknown-args check**

Append to the file:
```r
test_that("deprecation shim strips `script_path` before the unknown-args check", {
  new_test_db()
  s <- write_script('stow(data.frame(a = 1), "x")')

  expect_error(
    suppressWarnings(launch(script_path = s, bogus = 1)),
    "unknown arguments: bogus"
  )
})
```

- [ ] **Step 2: Finding 8 — add hash-equivalence assertion**

Append to the file:
```r
test_that("launch(script_path = { ... }) and launch(code = { ... }) produce the same step hash", {
  new_test_db()
  run_old <- suppressWarnings(launch(script_path = {
    stow(data.frame(a = 1), "x")
  }))

  new_test_db()
  run_new <- launch(code = {
    stow(data.frame(a = 1), "x")
  })

  expect_equal(run_old$step, run_new$step)
})
```

### Task 6: Regenerate man page and run the test suite

- [ ] **Step 1: Regenerate `man/launch.Rd`**

Run: `Rscript -e 'devtools::document()'`
Expected: `man/launch.Rd` updates to reflect the new `@param ...` and `@param code` wording.

- [ ] **Step 2: Run the deprecation tests**

Run: `Rscript -e 'devtools::load_all(quiet = TRUE); testthat::test_file("tests/testthat/test-launch-deprecated-args.R", reporter = "summary")'`
Expected: 6 passing tests (4 original + 2 new).

### Task 7: Commit

- [ ] **Step 1: Stage and commit**

```bash
git add R/launch.R man/launch.Rd tests/testthat/test-launch-deprecated-args.R \
        docs/api-reference.md docs/design.md NEWS.md \
        docs/superpowers/plans/2026-04-21-audit-fixes.md
git commit -m "fix(launch): apply audit findings from rename review

- Strip all script_path entries (not just first) when the shim runs.
- Rename NEWS section to 'Deprecations' and add removal timeline.
- Complete `@param ...` doc to mention the deprecated alias.
- Add SQL to the api-reference dispatch list.
- Add scope-clarifier sentence to design.md's execution-flow block.
- Cover shim edges: strips-before-unknown-args and hash-equivalence."
```
