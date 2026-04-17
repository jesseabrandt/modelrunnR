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

# Run your script as a tracked step. `stow()` calls inside the script
# are recorded; inputs and outputs are captured on a run row.
run <- launch("model.R")

# Read the latest version of any stored value.
latest  <- grab("predictions")

# Or a specific historical version.
pinned  <- grab("predictions", version = "a3f2...")
at_run  <- grab("predictions", from_run = run$run_id)
past    <- grab("predictions", as_of = "2026-04-01 00:00:00")

# See every stored version.
versions("predictions")

# Garbage-collect older versions when you're confident you don't need them.
prune_versions("predictions", keep = 3)
```

A `script.R` looks like this:

```r
# Inside model.R -- no library() needed; grab/stow are injected.
train <- grab("train_data")
fit   <- lm(y ~ x, data = train)
stow(fit,       "model")        # serialized via qs2
stow(predict(fit, train), "predictions")
```

## Key features

- **Content-addressed storage.** Stowing the same frame twice creates one
  physical table and one `_mr_versions` row. The hash is row- and
  column-order invariant.
- **Unified read/write API.** `grab()` and `stow()` work for both data frames
  (stored as DuckDB tables) and arbitrary R objects (stored as `qs2`
  artifacts, either as BLOBs or on disk above a size threshold).
- **Staleness diagnostics.** On `launch()`, modelrunnR compares the current
  script + helper bytes, recorded input hashes, and declared external inputs
  against the most recent run. Advisory only -- it never auto-skips.
- **External inputs.** Declare files and env vars that affect reproducibility
  via `launch(..., external_inputs = list(files = ..., env = ...))` and their
  hashes land on the run row.
- **Swappability — `rebind` and labeled variants.** `launch(..., rebind = list(features = my_df), label = "fast")` reruns the same script against different inputs and marks the run as a tracked variant. The `rebind` argument accepts bare R values (stowed inline) or reference constructors — `mr_hash()`, `mr_run()`, `mr_variant()`, `mr_as_of()` — that resolve to existing versions without round-tripping through R memory. Downstream scripts that grab a labeled variant's outputs auto-inherit the label. See [`docs/design.md`](docs/design.md) *Variants and swappability*.
- **Garbage collection.** `prune_versions()` removes versions by age, count,
  or "keep latest", with run-history protection.

## Documentation

- [`docs/design.md`](docs/design.md) — architectural decisions and rationale.
- [`docs/plan.md`](docs/plan.md) — v0.1 implementation slices.
- [`docs/followups.md`](docs/followups.md) — known trade-offs and deferred work.
- [`NEWS.md`](NEWS.md) — changelog.
