# modelrunnR

<!-- badges: start -->
<!-- badges: end -->

> **Status: early development (v0.1 pre-release).** APIs, schemas, and the
> on-disk format may still change.

**modelrunnR** turns model scripts into tracked runs. Wrap a block in
`launch({ ... })` and the package records what code ran — and, for
scripts that use `grab()` and `stow()`, what inputs they read and what
outputs they wrote — all to a single DuckDB file.

In practice the workflow is usually two-phase: stage runs ahead of time
with `queue()`, then pick them up later with `launch(mr_run(id))` — in
the same session, in another process, in a `furrr` map, or on an HPC
submit script. Inputs and outputs are content-addressed by hash; the run
log is itself a queryable table; `grab()` returns lazy DuckDB tbls so
you can filter or aggregate across runs in SQL without loading anything
into R memory.

## Installation

```r
# install.packages("pak")
pak::pak("jesseabrandt/modelrunnR")
```

## Tracked runs with `launch()`

`launch()` is the basic primitive: it executes a block and writes a row
to the run log capturing its code, inputs, outputs, timing, and status.

```r
library(modelrunnR)

# Stow source data once. `grab()` returns a lazy DuckDB tbl for tabular
# names; lm() collects it implicitly.
stow(mtcars, "cars", shape = "versioned")

launch({
  fit <- lm(mpg ~ wt + hp, data = grab("cars"))
  stow(fit, "model")
  stow(data.frame(rmse = sqrt(mean(residuals(fit)^2))), "metrics")
})

# Every launch's code body, inputs, and outputs are captured.
runs()                              # tibble; pull(code_body) prints the source

# Append-shape: one row per run.
grab("metrics", run = "all")

# Versioned-shape: one entry per distinct content.
versions("model")
grab("model")                       # latest
grab("model", version = "a3f2...")  # pinned by hash
```

## Stage now, execute later with `queue()`

The way modelrunnR is most often used: enumerate the runs you want now,
let them sit, then pick them up later. `queue()` writes a `_mr_runs` row
with `status = "queued"` but does not run the code.
`launch(mr_run(id))` picks the row up and updates it in place — no new
`run_id`.

```r
# Stage one run now.
q <- queue({
  fit <- lm(mpg ~ wt + hp, data = grab("cars"))
  stow(fit, "model")
})
q$status                            # "queued"

# Pick it up — same session, another process, or a furrr worker.
r <- launch(mr_run(q$run_id))
r$status                            # "success" — same row, status flipped
identical(r$run_id, q$run_id)       # TRUE

# Or stage a batch under one batch_id, varying the formula.
qs <- queue(
  {
    fit <- lm(grab("spec"), data = grab("cars"))
    stow(fit, "model")
  },
  rebind = mr_binds(spec = list(mpg ~ wt, mpg ~ wt + hp, mpg ~ wt + hp + cyl))
)
purrr::walk(qs$run_id, ~ launch(mr_run(.x)))
# Or in parallel:  furrr::future_map(qs$run_id, ~ launch(mr_run(.x)))
```

modelrunnR doesn't drive parallelism itself — `queue()` records, the
consumer executes. Compose with `future`/`furrr`, base R loops, or
shell-level job runners (`tsp`, an HPC submit script).

## Key features

- **Stage and pick up.** `queue()` enumerates runs without firing them;
  `launch(mr_run(id))` picks them up in place. Batch staging via
  `mr_binds()` writes N queued rows under one `batch_id`.
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
- **Swappability — `rebind` and labeled variants.** `launch(..., rebind = list(features = my_df), label = "fast")` reruns the same script against different inputs and marks the run as a tracked variant. The `rebind` argument accepts bare R values (stowed inline) or reference constructors — `mr_hash()`, `mr_run()`, `mr_variant()`, `mr_as_of()` — that resolve to existing versions without round-tripping through R memory.
- **Garbage collection.** `prune()` removes versions / runs by age, count,
  or "keep latest", with run-history and variant protection by default.

## Documentation

- Vignettes:
  [`getting-started`](vignettes/getting-started.Rmd) — full walkthrough
  including `queue()` and pickup;
  [`batch-launches`](vignettes/batch-launches.Rmd) — sweeps via `mr_binds()`;
  [`lazy-data`](vignettes/lazy-data.Rmd) — DuckDB tbls as inputs;
  [`nested-sweeps`](vignettes/nested-sweeps.Rmd) — composed sweeps.
- [`docs/design.md`](docs/design.md) — architectural decisions and rationale.
- [`NEWS.md`](NEWS.md) — changelog.

Internal planning docs, specs, audit followups, and AI-dev artifacts
live under [`docs/internal/`](docs/internal/).
