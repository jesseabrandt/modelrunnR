# modelrunnR Findings — AU-Catalog

This file logs real-use findings about the `modelrunnR` API as it's exercised
in the [AU-Catalog](../../../AU-Catalog/) project. AU-Catalog treats
`modelrunnR` as a dual-purpose collaborator: a tool for reproducible model
runs, *and* an API under test.

This file is separate from `TODO.md` so agents working on the package's own
backlog don't trip on cross-project findings.

## Format

Append entries as they come up. Each entry:

```
## YYYY-MM-DD — <short title>

**Context:** what we were trying to do
**Friction:** what was awkward, missing, confusing, or forced a workaround
**Workaround (if any):** what we did instead
**Suggested change:** a concrete API/docs/behavior suggestion, if clear
```

Findings are raw signal — not triaged decisions. The package maintainer
decides what (if anything) to change.

## Findings

## 2026-04-17 — First-use onboarding (AU-Catalog MiniLM wrap)

**Context:** Wrapping `python embed/embed_courses.py` (a ~10-minute sentence-transformer run) inside `launch({...})` so reruns with unchanged code + inputs are cached. First live use of modelrunnR outside its own tests.

Below is a batch of findings from that single session. Each is raw signal — maintainer triages.

### F1 — No install path for a downstream consumer

**Friction:** Package is not on CRAN, not installed globally. A sibling repo consuming it has to reach in via `devtools::load_all("/workspace/r-packages/modelrunnR")`. That's fine for a dev-time tool exercised from within the same workspace, but it's the first thing a new user writes and it doesn't feel like the steady-state pattern.

**Workaround:** `devtools::load_all()` at the top of each runner script.

**Suggested change:** Either (a) README briefly shows the three install paths (load_all for workspace dev, `devtools::install_local()` for a fixed snapshot, `remotes::install_github()` once published) with a recommendation, or (b) document that `devtools::load_all()` is the intended pattern while the package is pre-1.0 and commit to that.

### F2 — `stow()` doesn't accept a file path (forced hand-hashing)

**Friction:** For a large on-disk artifact the package shouldn't round-trip through R memory (here: a ~60 MB Parquet of 42k×384 embeddings), the user must hash the file themselves and `stow()` the hash string. Package already knows how to hash files (`.mr_file_hash`, used for `external_inputs`), but that knowledge isn't exposed.

**Workaround (AU-Catalog/embed/run_embed.R):**
```r
parquet_hash <- unname(tools::md5sum(PARQUET))
stow(parquet_hash, "embeddings_parquet_hash")
```

**Suggested change:** `stow_file(path, name)` that records a file-kind artifact (stores path + content hash + size in `_mr_versions`, no R-side materialization). Staleness becomes automatic — downstream `grab("embeddings_parquet_hash")` returns the hash; or better, downstream `grab_file("embeddings_parquet")` returns the path and signals staleness if the hash mismatches. Large scientific datasets (parquet, npz, .pt, GeoTIFF) are a common-enough case that this helper would pay off fast.

### F3 — No helper for tracking a shell-out to another language

**Friction:** The design doc explicitly rejects a Python harness — fine, that keeps the scope clean. But every non-R integration will reinvent the same 4–5 lines: `system2 → check exit code → assert output files exist → stow outputs`. The pattern is uniform enough that it wants a helper.

**Workaround:** Wrote it by hand inside `launch({...})`.

**Suggested change:** Either (a) a vignette titled something like *"Orchestrating Python (or any external) runs"* that shows the canonical pattern, or (b) a small helper like `mr_shell_out(command, args, expect_files = character())` that wraps `system2`, checks exit, verifies declared outputs, and `stow()`s a result summary. Not a harness — just the glue everyone will write.

### F4 — No `@examples` on exports

**Friction:** `?launch` and `?grab` document behavior in prose only. For `external_inputs` specifically, I couldn't tell from the roxygen whether the list shape was `list(files = c(...), env = c(...))` or `list(files = list(...))` or something else. Confirmed only by reading `.mr_resolve_external_inputs`.

**Workaround:** Read `R/launch.R:53-57` and `R/staleness.R:*` for the actual shape.

**Suggested change:** A minimal `@examples` block on each exported function. For `launch()`, at least one example showing `external_inputs = list(files = c(...))`. (This is already on `docs/followups.md` as "No `@examples`" — repeating here for weight: this was the single highest-cost onboarding friction in my session.)

### F5 — `external_inputs` vs `rebind` use inconsistent list shapes

**Friction:** Both parameters declare run-time inputs, but their conventions differ:
- `rebind` — flat named list: `list(training = df, ref = mr_hash(h))`.
- `external_inputs` — nested sub-list with fixed field names: `list(files = c(...), env = c(...))`.

A reader sees two "inputs" concepts with two shapes and has to remember which is which. Not a bug; a consistency wart.

**Suggested change:** Document the distinction explicitly in a single place (both parameter docs cross-reference a Design Note), or consider unifying under a single declaration mechanism. Low priority.

### F6 — `launch()` block can't return values out-of-band (stow is the only channel)

**Friction:** In ordinary R you'd write `x <- some_block({ ... final_expr })`. With `launch({ ... })`, the return value is the run record, and anything produced inside must be `stow()`-ed to be retrievable. This is a clean contract but easy to trip on the first few uses — I reflexively wrote `result <- launch({... meta <- fromJSON(...); meta })` expecting `result` to be `meta`.

**Workaround:** Call `stow(meta, "embeddings_meta")` then `grab("embeddings_meta")` after the run.

**Suggested change:** One sentence in `?launch` emphasizing: *"The block's return value is discarded. Use `stow()` to surface results. The `run` returned by `launch()` is the run record, not the block result."*

### F8 — **Resolved (2026-04-17):** `launch()` now skips fresh runs by default

Fixed in the 0.0.0.9000 dev cycle. `launch()` gained a `force = FALSE`
argument and defaults to skip-on-fresh: a step that is fresh under the
current label no longer evaluates its block. A `_mr_runs` row with
`status = "skipped_fresh"` is written for provenance. Users who want
the prior advisory-only behavior set
`options(modelrunnR.skip_if_fresh = FALSE)`. The internal staleness
check is now exposed as `is_stale(mr_label("..."))` for users who want
to gate their own logic without calling `launch()`. See `NEWS.md`.

Original finding text preserved below for historical context:

### F8 — **Critical:** `launch()` never auto-skips a fresh run (staleness is advisory)

**Friction:** I expected `launch({ expensive_work })` to check staleness and, if nothing changed, *not run* the block. That's the mental model of a cache. `launch()` does not do that. From `R/launch.R:149`: *"Advisory staleness check -- report only, never auto-skip."* It prints `is fresh` and then runs the block anyway.

The vignette even shows this behavior, with `"[success] in <1 ms (1 grabs, 2 stows)"` as the "fresh" rerun. That <1 ms cost hides the design choice: if the block is cheap, reruns are free; if the block shells out to a 90-minute Python job, reruns are 90 minutes.

This bit me hard. The whole point of wrapping `python embed/embed_courses.py` in `launch()` was to avoid the second 90-minute run after iterating on downstream code. I got a second 90-minute run.

**Workaround:** Write a manual skip gate *inside* the launch block using external files I control (`embeddings_meta.json` carries an `input_csv_sha256`; my revised `embed/run_embed.R` compares that to the current CSV's hash and short-circuits the `system2(...)` call when they match). modelrunnR still records the run, but the expensive work is gated outside its machinery.

**Suggested change:** Either (1) add `skip_if_fresh = FALSE` (default) to `launch()` — when TRUE, skip block execution on a fresh result; or (2) expose a public `is_stale(step, external_inputs = ...)` so users can write `if (is_stale(...)) launch({...}) else { report cached run }` cleanly, without reaching into `.mr_is_stale`; or (3) prominently document in `?launch` and the getting-started vignette that staleness is advisory, with a canonical "skip-if-fresh" recipe. My preference is (1): the advisory-only design is a reasonable default for fast R blocks but a footgun for the "wrap an expensive external run" use case that the package's own motivation strongly suggests. A single opt-in flag preserves both paths.

**Related discovery:** `.mr_is_stale()` is internal; there is no public "is this stale?" function. Without (1) or (2), a user-written skip gate has no way to reuse modelrunnR's own notion of staleness and must reinvent it from external cues. This almost inverts the value proposition — modelrunnR knows what's stale, but users re-derive it to act on it.

### F7 — Minor: `rebind` reference constructors feel over-exported at first glance

**Friction:** Six exports (`mr_hash`, `mr_run`, `mr_variant`, `mr_as_of`, plus `versions`, `variants*`) are specialist enough that a new user scanning `ls("package:modelrunnR")` has to work out which three or four to focus on.

**Suggested change:** Not a fix — a README "Getting Started" ordering: the core handful (`launch`, `stow`, `grab`, `ingest`, `versions`) then a "Advanced" section for refs/variants.

---

*(Will append more as the AU-Catalog work exercises more of the API. Findings covering grab/versions/variants/prune, schema migrations, and multi-session behavior not yet captured.)*
