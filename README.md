# modelrunnR

<!-- badges: start -->
<!-- badges: end -->

> **Status: early development (v0.1 pre-release).** APIs, schemas, and the
> on-disk format may still change.

**modelrunnR** gives you reproducible model-run orchestration for R with
content-hashed versioning, staleness diagnostics, and a single-file DuckDB
backing store. Swap `source("model.R")` for `launch("model.R")` and every
data frame or artifact the script `stow()`s is automatically versioned,
deduplicated by content hash, and retrievable by hash, run id, or timestamp.

## Installation

```r
# install.packages("pak")
pak::pak("jesseabrandt/modelrunnR")
```

## Before / after

**Before:**

```r
source("model.R")
# Which inputs did this run read? Which outputs did it write?
# Which version of the training data did we use last Thursday?
# I have no idea.
```

**After:**

```r
library(modelrunnR)

# Stow source data once. `grab()` returns a lazy DuckDB tbl for tabular
# names; lm() collects it implicitly.
stow(mtcars, "cars", shape = "versioned")

# Launch 1: formula inline.
launch({
  fit <- lm(mpg ~ wt + hp, data = grab("cars"))
  stow(fit, "model")
  stow(data.frame(rmse = sqrt(mean(residuals(fit)^2))), "metrics")
})

# Promote a (different) formula into the store so other launches can share it.
stow(mpg ~ wt + hp + cyl, "spec")

# Launch 2: same outputs, but the formula now lives in the store.
# Both launches share state via the .duckdb file -- no R-side handoff.
launch({
  fit <- lm(grab("spec"), data = grab("cars"))
  stow(fit, "model")
  stow(data.frame(rmse = sqrt(mean(residuals(fit)^2))), "metrics")
})

# Every launch's code body, inputs, and outputs are captured.
runs()                              # tibble; pull(code_body) prints the source

# Append-shape: one row per run.
grab("metrics", run = "all")        # both runs, with run_id + variant_label

# Versioned-shape: one entry per distinct content. Both fits are kept.
versions("model")
grab("model")                       # latest
grab("model", version = "a3f2...")  # pinned by hash

# Garbage-collect by age, count, or "keep latest" (dispatches on shape).
prune("model", keep = 3)
```

## Key features

- **Two storage shapes, one API.** Data frames you `stow()` inside runs
  append to a single growing table per name (run-indexed). Non-tabular
  artifacts and ingested reference data are content-addressed by hash.
  `grab()`, `versions()`, and `prune()` work on both without you needing
  to know which is which.
- **Unified read/write API.** `grab()` and `stow()` cover data frames,
  lazy DuckDB tbls (materialized server-side), and arbitrary R objects
  (serialized via `qs2`).
- **Staleness diagnostics.** On `launch()`, modelrunnR compares the current
  script + helper bytes, recorded input hashes, and declared external inputs
  against the most recent run. Advisory only -- it never auto-skips.
- **External inputs.** Declare files and env vars that affect reproducibility
  via `launch(..., external_inputs = list(files = ..., env = ...))` and their
  hashes land on the run row.
- **Swappability — `rebind` and labeled variants.** `launch(..., rebind = list(features = my_df), label = "fast")` reruns the same script against different inputs and marks the run as a tracked variant. The `rebind` argument accepts bare R values (stowed inline) or reference constructors — `mr_hash()`, `mr_run()`, `mr_variant()`, `mr_as_of()` — that resolve to existing versions without round-tripping through R memory. Downstream scripts that grab a labeled variant's outputs auto-inherit the label. See [`docs/design.md`](docs/design.md) *Variants and swappability*.
- **Garbage collection.** `prune()` removes versions / runs by age, count,
  or "keep latest", with run-history and variant protection by default.

## Documentation

- [`docs/design.md`](docs/design.md) — architectural decisions and rationale.
- [`docs/plan.md`](docs/plan.md) — v0.1 implementation slices.
- [`docs/followups.md`](docs/followups.md) — known trade-offs and deferred work.
- [`NEWS.md`](NEWS.md) — changelog.
