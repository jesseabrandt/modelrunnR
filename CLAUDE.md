# CLAUDE.md — modelrunnR

This file gives Claude Code (claude.ai/code) context for working in this
repository.

## What this is

**modelrunnR** is an R package (early development) for orchestrating R and
Python model runs through a common harness interface and lightweight,
configuration-driven model specs.

## Inspiration

The orchestration layer is inspired by the sibling package
[`panelmodeler`](../../Practicum_AI_Branch/panelmodeler), specifically its
harness + runner files:

- `R/runner.R` — top-level dispatch
- `R/harness_common.R`, `R/harness_cv.R`, `R/harness_predict.R`,
  `R/harness_rolling_window.R` — shared harness scaffolding and mode-specific
  harnesses
- `R/model.R`, `R/model_specs.R`, `R/new_model_spec.R` — model spec objects
- `R/python_model.R` — R→Python model invocation
- `R/stack.R` — stacked/composed model handling

In panelmodeler these live alongside panel-data ingestion, feature engineering,
and reporting; `modelrunnR` extracts and generalizes the orchestration piece so
it can be reused outside the panel-data context.

## Package scaffolding

Built following [*R Packages* (2e), "The Whole Game"](https://r-pkgs.org/whole-game.html)
with `usethis`/`devtools`:

- `usethis::create_package()` — DESCRIPTION, NAMESPACE, R/
- `usethis::use_mit_license("Jesse Brandt")`
- `usethis::use_package_doc()` — `R/modelrunnR-package.R`
- `usethis::use_testthat(3)` — `tests/testthat/`
- `usethis::use_roxygen_md()` — markdown in roxygen

## Development workflow

Use `devtools` from R:

```r
devtools::load_all()     # iterate on code
devtools::document()     # regenerate NAMESPACE + man/ from roxygen
devtools::test()         # run testthat suite
devtools::check()        # full R CMD check
```

## Conventions

- One function per file in `R/` where practical; name the file after the
  function.
- Roxygen2 with markdown for docs; `@export` only user-facing functions.
- Tests in `tests/testthat/test-<topic>.R`; prefer small, focused tests.
- Keep the package lean — add dependencies to `Imports` only when needed.

## Notes for Claude

- When adding harness or runner code, check how `panelmodeler` solves the same
  problem first (path above) and generalize rather than copy.
- Don't add features, refactor, or introduce abstractions that weren't asked
  for. This package starts minimal.
- If a task requires running R, use `Rscript -e '...'` from `Bash`. Prefer
  `devtools::load_all()` over installing the package for iterative work.
