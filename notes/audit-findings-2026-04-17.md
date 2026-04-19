# Audit Findings — Getting-Started Vignette + Called Functions

**Date:** 2026-04-17
**Target:** `vignettes/getting-started.Rmd` and the R functions it exercises
(`stow`, `grab`, `launch`, `launch_code`, `mr_label`, `versions`, `variants`,
`db_path`, `project_root`, `connection`).
**Reviewers dispatched:** code, readability, pipeline, stats.
**Scope:** vignette-anchored; helper-file findings included only when they
affect vignette correctness or the API it demonstrates.

Status: raw, un-triaged. Maintainer decides what to act on.

---

## Errors (1)

### A1 — `variants()` prose is factually wrong
**Sources:** [pipeline, code]
**Location:** `vignettes/getting-started.Rmd:155`

The prose after the `variants()` chunk says "Two runs of `baseline`, both
tied to the same label." By that point there are **3** tracked runs under
label `baseline` (launch + rerun + iterate). Inline blocks key on expression
bytes, so `variants()` actually returns **2 rows** (one per `<inline:hash>`
step): one with `n_runs = 2`, one with `n_runs = 1`.

**Fix:** Either rewrite the prose to explain that inline edits produce a new
step identity (so "two rows, three runs total"), or switch this section to a
`.R` file example so `step` is stable across edits and the simpler narrative
holds.

---

## Warnings (11)

### A2 — `stow()` row-names warning fires on every tracked `launch()`
**Sources:** [code]
**Location:** `vignettes/getting-started.Rmd:80-92, 114-126, 134-146`;
triggered by `.mr_has_nondefault_rownames()` at `R/stow.R:69-76`

`data.frame(y, pred = predict(model, training))` inherits row names from
`predict.lm()`'s named vector, firing the warning on the reader's first
tracked run. Visible on every rendered tracked chunk in the vignette.

**Fix:** Minimal — `unname(predict(...))` in the vignette. Better —
`.mr_has_nondefault_rownames` shouldn't warn when row names came from a
named vector.

### A3 — "Fresh" rerun chunk still prints a reproducibility warning
**Sources:** [code]
**Location:** `vignettes/getting-started.Rmd:114-126`

Prose says "no new version is written"; reader sees a warning on the same
chunk because `training` was stowed at the REPL. The two messages contradict
each other in tone.

**Fix:** Either suppress with `warning = FALSE` in the chunk header, or move
the initial `stow(df, "training")` inside a tracked `launch()` so downstream
grabs don't trip the interactive-input check.

### A4 — `run$inputs` / `run$outputs` are JSON strings, prose doesn't warn
**Sources:** [code, readability, pipeline]
**Location:** `vignettes/getting-started.Rmd:100-102`; origin
`R/launch.R:362-365`

Reader sees a JSON blob where they expect structured R output.

**Fix:** Parse with `jsonlite::fromJSON()` in the chunk, or add a sentence
explaining the JSON storage.

### A5 — Terminology drift: label / pipeline / version / variant overlap
**Sources:** [readability]
**Location:** `vignettes/getting-started.Rmd:73-99, 128-158`

Four terms for 2–3 concepts. Also: `version` is used for both artifact
versions (`versions()`) *and* successive runs of the same variant.

**Fix:** Pick one noun for the labeled thread (recommend "variant" to match
the code), then explicitly disambiguate the two senses of "version" on first
use.

### A6 — `run$variant_label` is printed before "variant" is introduced
**Sources:** [readability]
**Location:** `vignettes/getting-started.Rmd:96-102`

`variants()` doesn't arrive until line 148, but the field name surfaces much
earlier.

**Fix:** Drop that field from the early inspection, or add a one-line bridge.

### A7 — Staleness / timing message promised in prose but never shown
**Sources:** [readability]
**Location:** `vignettes/getting-started.Rmd:70-71, 110-112`

The bullet "a staleness line prints before the run" doesn't ship an example
of what that line looks like.

**Fix:** Paste a sample `modelrunnR: <inline:…> is fresh` line into prose, or
set `message = TRUE` and call out the format.

### A8 — "Under the hood" ends mid-thought
**Sources:** [readability, code]
**Location:** `vignettes/getting-started.Rmd:186-199`

Opens with plural "A few things happen" then covers one topic.

**Fix:** Rename the section to "Where the DuckDB store lives", or add a short
paragraph on inline-step identity and label auto-propagation.

### A9 — Cleanup chunk doesn't restore `options(modelrunnR.db)`
**Sources:** [pipeline]
**Location:** `vignettes/getting-started.Rmd:200-204`

A user-set value is silently clobbered and not restored.

**Fix:** Save `getOption("modelrunnR.db", NULL)` in the setup chunk, restore
it in cleanup.

### A10 — Cleanup chunk doesn't fire if any earlier chunk errors
**Sources:** [pipeline]
**Location:** `vignettes/getting-started.Rmd:200-204`

With knitr default `error = FALSE`, a mid-render failure leaves the DuckDB
connection open and the tempfile DB on disk.

**Fix:** Hoist cleanup into a `knitr::knit_hooks$set(document = …)` hook, or
set `error = TRUE` globally so cleanup still runs.

### A11 — `launch("fit.R", label = "baseline")` example doesn't explain inheritance
**Sources:** [code]
**Location:** `vignettes/getting-started.Rmd:182-184`

Reader just learned `launch(mr_label("baseline"))` auto-inherits labels; now
sees `label = "baseline"` passed explicitly on a file launch.

**Fix:** One sentence — first file launch sets the label; subsequent
`launch("fit.R")` calls auto-inherit.

### A12 — Relaunch section uses "inline" / "file" vocabulary before introduction
**Sources:** [readability]
**Location:** `vignettes/getting-started.Rmd:161-173`

"From block to script" (which names the two modes) comes *after* this
section.

**Fix:** Swap the ordering, or reword to avoid the terms.

---

## Suggestions (10)

### A13 — `:::` in cleanup chunk
**Sources:** [code]
**Location:** `vignettes/getting-started.Rmd:202`

`modelrunnR:::.mr_reset_connection()`. `R CMD check` can flag `:::` in
vignette source.

**Fix:** Export a user-facing `mr_reset_connection()`, or call
`DBI::dbDisconnect()` directly.

### A14 — `grab()` `@return` docs out of date
**Sources:** [code]
**Location:** `R/grab.R:43`

Says "A data frame."; `grab()` also returns artifacts.

**Fix:** "The stored value (data frame for table-backed names, any R object
for artifact-backed names)."

### A15 — `versions()` output wraps awkwardly in `html_vignette`
**Sources:** [code]
**Location:** `vignettes/getting-started.Rmd:107`

**Fix:** 12-char truncation of `content_hash` (matching step ids at
`R/launch.R:110`), or demonstrate
`versions("predictions")$produced_by_runs` to unpack the list column.

### A16 — "compare variants, and garbage-collect old versions" oversells coverage
**Sources:** [code]
**Location:** `vignettes/getting-started.Rmd:77-78`

Neither is demonstrated here.

**Fix:** Drop the sentence or add a `?prune_variants` / `grab(variant = ...)`
pointer.

### A17 — `prune_variants()` / `prune_versions()` mentioned without pointer
**Sources:** [code, readability]
**Location:** `vignettes/getting-started.Rmd:155-157`

**Fix:** Cross-reference `?prune_variants` / `?prune_versions`.

### A18 — `launch_code()` is never mentioned
**Sources:** [readability]

Decide: is it getting-started-level? If so, two lines after the relaunch
section would complete the "you can re-run *and* inspect" mental model.
Otherwise leave it to `?launch_code`.

### A19 — `launch("fit.R", ...)` example is a plain `r` fence (unevaluated)
**Sources:** [readability]
**Location:** `vignettes/getting-started.Rmd:182-184`

**Fix:** If keeping it minimal, one sentence noting that helper files
sourced inside the script are tracked too — see `?launch`.

### A20 — "Even when called at the REPL… interactive write" hook is dropped
**Sources:** [readability]
**Location:** `vignettes/getting-started.Rmd:50-53`

**Fix:** Either demonstrate the downstream warning it produces, or drop the
forward reference.

### A21 — `launch()` substitute/`is.call` dispatch edge in roxygen
**Sources:** [code]
**Location:** `R/launch.R:88-89`

`launch(my_path_var)` works; `launch(identity({ ... }))` would be treated as
a path. Worth a note in `@section Script, inline, and relaunch modes:`. The
vignette itself is fine.

### A22 — No note on `set.seed()` for stochastic models
**Sources:** [pipeline]
**Location:** `vignettes/getting-started.Rmd:34-40`

A reader extending the scaffold with a random forest will produce a new
outputs hash on every run despite "fresh" being reported.

**Fix:** One sentence — put `set.seed()` *inside* the `launch({...})` block
so code-hash + seed together pin stochastic outputs.

---

## Stats review
Clean. No statistical-correctness issues — vignette correctly keeps its
statistical surface minimal and avoids misleading framings
(in-sample-as-evaluation, "interaction improves fit" without evidence, etc.).
