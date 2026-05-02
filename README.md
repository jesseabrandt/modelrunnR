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

# Stow inputs to the project's DuckDB store (one file, content-hashed).
# Re-running these calls is idempotent -- identical content is deduped.
stow(mtcars, "cars", shape = "versioned")
stow(mpg ~ wt + hp, "spec")

# Launch 1: fit the model on the full data.
launch({
  fit <- lm(grab("spec"), data = grab("cars"))
  stow(fit, "model")
})

# Launch 2 (could be a different script, session, or machine sharing
# the .duckdb file): re-fit on a holdout subset using the same spec.
# Both launches share state via the store -- no R-side handoff.
launch({
  fit_holdout <- lm(grab("spec"), data = head(grab("cars"), 20))
  stow(data.frame(rmse_full    = sqrt(mean(residuals(grab("model"))^2)),
                  rmse_holdout = sqrt(mean(residuals(fit_holdout)^2))),
       "metrics")
})

grab("metrics")                     # one row from this run
grab("metrics", run = "all")        # all rows once you re-run, with run_id + variant_label

# Non-tabular artifacts are content-addressed by hash:
grab("model")                       # latest content
grab("model", version = "a3f2...")  # pinned by hash

# See every stored version / append chunk (works on both shapes).
versions("metrics")
versions("model")

# Garbage-collect older data. Dispatches on shape.
prune("model",   keep = 3)             # keep 3 latest versions (versioned-shape)
prune("metrics", keep = 3)             # keep 3 latest runs' rows  (append-shape)
prune(older_than = "30d", by = "age")  # shape-agnostic
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
