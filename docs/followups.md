# Followups

Tracked trade-offs and deferred work from the v0.1 audit. Nothing here is a
bug — these are conscious post-v0.1 improvements captured so they don't get
lost. Each entry lists the file:line anchor so you can jump straight to the
code, and the audit reviewer that flagged it.

## Performance

- **O(runs × outputs) R-side JSON scan in `versions()`** — `R/versions.R:37-39`.
  Loads every `_mr_runs.outputs` row, parses each JSON in R, scans pairs. Fine
  at v0.1 scale; revisit when run histories exceed ~1k rows. Consider pushing
  the filter into DuckDB via `json_extract_string`. `[code]`

- **Same pattern in `.mr_last_producer_step()`** — `R/interactive.R:41-61`.
  Called on every `launch()`; grows unboundedly with run history. `[code, pipeline]`

- **Same pattern in `.mr_protected_version_hashes()`** — `R/prune_versions.R:122-147`.
  Now returns `(name, hash)` pairs (slice-1 fix) but still iterates all runs.
  `[code]`

- **Grow-in-loop vectors in JSON aggregation** — `R/prune_versions.R:131-143`,
  `R/recording.R:40-41, 51-52`. Pre-allocate with `vector("list", n)` or switch
  to `vapply` / `purrr::map` when run count is large. `[code]`

- **`size_bytes` measures R memory, not DuckDB storage** — `R/stow.R:73`.
  `object.size()` overstates on-disk cost because DuckDB columnar compression
  typically shrinks frames by 5–10×. Users inspecting `versions()` for
  gc decisions see inflated numbers. Use DuckDB `estimated_size` or document
  as an R-side memory estimate. `[code, pipeline]`

- **Double-pass over labeled-runs in propagation** —
  `R/propagation.R`. `.mr_propagate_label()` calls
  `.mr_label_for_produced_hash()` once per input (N walks of
  `_mr_runs WHERE variant_label IS NOT NULL`); on inheritance success
  the launch path then calls `.mr_first_input_producing()`, which
  walks the inputs AGAIN with the same per-input full-table-scan
  pattern, paying 2N table scans for an inheritance event. The
  single-pass fix is to have `.mr_propagate_label()` return
  `list(label, source_name)` directly so the caller doesn't need a
  second pass; this can land alongside the broader O(runs × outputs)
  refactor flagged elsewhere in this section. `[code]`

- **`.mr_read_value` uses `readBin` instead of `qs2::qs_read`** —
  `R/grab.R:85`. Loads the entire file into a raw vector, then deserializes.
  `qs2::qs_read(path)` reads directly from the path. Marginal for small
  artifacts; noticeable at the blob/file threshold. `[code]`

## API polish

- **`.mr_parse_duration()` rejects uppercase units and weeks** —
  `R/prune_versions.R:111`. Regex is `^([0-9]+)\s*([smhd])$`. `"1w"` and `"1D"`
  are sensible user inputs. Add `w = n * 604800` and a `tolower()` pass. `[code]`

- **`.mr_file_hash()` silently returns NA for directories** —
  `R/hash_file.R:7-12`. `file.exists(dir)` is `TRUE`; `tools::md5sum(dir)`
  returns `NA_character_`. User gets a confusing downstream staleness result
  instead of an up-front error. Guard with `dir.exists(path)` → `stop()`. `[code]`

- **`stringsAsFactors = FALSE` passed without declaring `R (>= 4.0)`** —
  `R/launch.R:159`, `R/interactive.R:32`, `DESCRIPTION`. Redundant in R ≥ 4.0
  (default changed). Declare `Depends: R (>= 4.0)` in DESCRIPTION or drop the
  argument. `[code]`

- **Interactive run-row builder drifts from `launch.R`** —
  `R/interactive.R:24-33` vs `R/launch.R:148-160`. Two hand-maintained column
  lists; future schema additions force a double update. Extract a single
  `.mr_build_run_row()` helper that fills unspecified columns with defaults.
  `[code]`

- **`paste()`-based dedup key collision risk in `variants_unexplored()`** —
  `R/variants_unexplored.R` around line 81. `paste()` with default space
  separator could collide when a label or name contains an internal space
  (e.g., `("a b", "c", h)` vs `("a", "b c", h)` both produce `"a b c h"`).
  Hashes are 32-char hex (no spaces) so hash-positional collisions are not
  reachable, but the name/label span is. Label validation currently allows
  internal whitespace. Fix: use a separator provably excluded by name/label
  validation (e.g., `sep = "\x00"`) or tighten label validation to forbid
  internal whitespace. Low-probability but worth pinning before multi-word
  labels become common. `[code]`

## Tests

- **`Sys.sleep(0.01)` flake risk** — `tests/testthat/test-versioning.R:25`.
  10 ms is below the filesystem/clock resolution on some platforms. Bump to
  50 ms for consistency with the same file's lines 107/109. `[code]`

- **Missing coverage** — the following regressions were added in slices 1–4
  but some adjacent cases are still untested:
  - `stale_steps()` path once it lands (blocked on the function itself).
  - Empty-frame hashing delimiter consistency (below).
  - Explicit int/double sensitivity test pinning the contract. `[code, math]`

## Documentation

- **No `@examples` on any exported function** — `R/launch.R`, `R/grab.R`,
  `R/stow.R`, `R/ingest.R`, `R/versions.R`, `R/prune_versions.R`, `R/db_path.R`.
  `?grab` has three precedence-ordered selectors explained in prose but not
  shown in code. Use `\dontrun{}` to avoid DB side effects during `R CMD check`.
  `[readability]`

- **Inconsistent `@noRd` / roxygen on internals** — `R/staleness.R:13-24`
  (has `@keywords internal` + generated `.Rd`) vs everything else (no roxygen,
  just `##` file-level comments). Pick one convention and apply uniformly.
  `[readability]`

- **Vocabulary drift between `kind` and `storage_location`** —
  `R/schema.R:50-67`, `R/stow.R:71, 95, 130`, `R/grab.R:63-87`,
  `R/prune_versions.R:139-161`. The concepts are nested (`kind` is table/artifact;
  `storage_location` is blob/file for artifacts only) but there's no one-paragraph
  legend in the code. Add a comment block at the top of `R/schema.R` spelling out
  the vocabulary. `[readability]`

- **`R/pin.R` filename vs convention** — CLAUDE.md says "one function per file
  in `R/` where practical; name the file after the function." `R/pin.R` defines
  `.mr_resolve_pins`, `.mr_start_pinning`, etc., not a `pin()` function. Either
  rename to `R/pinning.R` (aspect-file pattern) or document the convention
  exception. `[readability]`

- **`CLAUDE.md` inspiration section references `panelmodeler` functions not
  borrowed** — the listed files (`runner.R`, `harness_*.R`, `model.R`,
  `model_specs.R`, `python_model.R`, `stack.R`) describe a path the design
  explicitly rejected. A new contributor reading CLAUDE.md first will chase
  a dead lead. Update to reflect what v0.1 actually borrowed (entry-point
  vocabulary, nothing else). `[readability]`

## Data integrity (future)

- **Crash window between `writeBin()` and `dbBegin()` in `.mr_stow_artifact`**
  — `R/stow.R:112-134`. For filesystem artifacts, the bytes are written to
  disk *before* the transaction around the `_mr_versions` insert begins, so
  a crash in that narrow window would leave an orphan `.qs2` file that the
  rollback handler never runs against. The file is safely named
  (`<name>__<hash16>.qs2`) and can be recovered manually, but a startup-time
  scan that compares `modelrunnR_artifacts/` against `_mr_versions` and
  reports orphans would close the gap. Lower-risk than the in-transaction
  crash recovery already covered. `[code]`

## Security (future)

- **MD5 → SHA-256 migration** — `R/hash_file.R`, `R/hash_artifact.R`,
  `R/hash_code.R`, `R/backend_duckdb.R:96, 109`. MD5 is cryptographically
  broken (chosen-prefix collisions are practical). In a shared-project workflow
  a malicious project could supply pre-images. v0.1 is local-first, so the
  practical risk is low — but flip before `.duckdb` files propagate because
  it's a breaking schema change. `[security, math]`

- **Wrap DuckDB concurrency error with a modelrunnR-specific message** —
  `R/connection.R`. Two R sessions hitting the same DB file fail with a raw
  DuckDB lock error, not a modelrunnR message. Wrap `.mr_connect()` in
  `tryCatch` and re-throw with "another R session is already connected to
  this project". `[security]`

- **`.mr_protected_version_hashes` should warn on malformed JSON, not
  silently return empty** — `R/prune_versions.R:130-133`. A corrupted
  `outputs` row currently produces an empty `pairs` list, which can cause
  `prune_versions()` to under-protect versions that should have been kept.
  Fail-safe direction is to warn the user rather than silently widen
  the prune set. `[security]`

## Hashing (future)

- **Empty-frame delimiter consistency** — `R/backend_duckdb.R:94-98`.
  Non-empty path uses `|` as the row separator; empty path uses `|` between
  the sentinel and column list but `,` within the column list. A unit
  separator (`chr(31)`) would be a cleaner convention and wouldn't collide
  with content. `[math]`

- **Total-order tiebreaker for `STRING_AGG ORDER BY HASH()`** —
  `R/backend_duckdb.R:108-111`. 64-bit HASH collisions (~0.03% probability
  at 100M rows) defeat row-order invariance on the colliding tie. Add a
  secondary sort key (e.g., `CONCAT_WS(chr(31), cols)`) at some performance
  cost. Low priority at v0.1 scale. `[math]`

- **Explicit test for int vs double sensitivity** — `tests/testthat/test-versioning.R`.
  The hashing contract is documented (slice-2 roxygen on `stow()`) but no test
  pins the decision. Add a test asserting `stow(data.frame(a = 1L))` and
  `stow(data.frame(a = 1.0))` produce different hashes. `[math]`

- **Streaming aggregate hashing for 100M+ row frames** — `R/backend_duckdb.R:91-113`.
  Current `STRING_AGG + MD5` materializes a ~2 GB intermediate at 100M rows.
  A commutative O(1)-state accumulator (e.g., homomorphic hash + addition
  modulo a large prime) or a chunked fold over the sorted stream would
  eliminate the intermediate. Blocked on a benchmarking pass to confirm
  real-world need. `[math, design]`

## Deferred v0.1 features

- **`stale_steps()` helper** — originally optional in `docs/plan.md` slice 10.
  Returns a data frame of stale steps across all `_mr_runs` paths. Out of
  scope for the audit-remediation slice. Implement post-v0.1 if users ask.
  `[design]`

- **Bulk variant operations** — `rename_variant(script, old_label, new_label)`
  for fixing label typos, `launch_unexplored(script)` to actually run the
  missing combinations surfaced by `variants_unexplored()`, and an automatic
  labeled-cascade mode on `prune_variants(..., cascade = TRUE)` that walks
  downstream labeled variants. All deferred from the swappability design
  (see `design.md` *Variants and swappability*). Cascade deletion is
  policy-heavy; hold until real usage shows the right default. `[design]`

- **Virtual stow / inline recomputation** — a per-name knob marking an
  intermediate as "virtual": not materialized to disk, recomputed on demand
  by recursively re-launching the producing script. Swaps storage cost for
  compute cost; useful when intermediates are cheap to compute (~seconds)
  but expensive to store (~100s of MB). Composes cleanly with variants —
  `grab("features", variant = "eta_0.01")` would recompute that upstream.
  Architectural hooks to preserve in v0.1: keep the grab-side read path in
  `R/grab.R` free of "rows are always stored" assumptions so a future
  `materialization` column check drops in at the top of the resolver; keep
  any `_mr_versions.materialization` column addition purely additive. The
  user-facing shape (package-wide option, per-stow flag at write time, or
  per-name marker) is explicitly unresolved. `[design]`

- **Script move detection + `rename_step()`** — if a user moves
  `fit_xgb.R` to `models/fit_xgb.R`, naive launching creates fresh runs
  under the new `step` path, visually splitting history. `_mr_runs.code_hash`
  already provides a near-free detection signal: a new launch whose
  `code_hash` matches prior runs under a different `step` path is
  (probably) a move. Surface as an advisory message at launch time, and
  offer `rename_step(old_path, new_path)` — a ~20-line UPDATE over
  `_mr_runs` rewriting the `step` column. Automatic silent re-parenting
  is rejected: two unrelated near-empty scripts can share a `code_hash`
  in principle, and silent re-parenting on a false positive is a bad
  failure mode. `[design]`

- **Label validators** — v0.1 labels are free-text. Typo drift
  (`"eta_0.01"` vs `"eta_.01"`) is a real risk users can self-police in
  loop bodies. Post-v0.1, consider a label registry or a
  `valid_labels = c(...)` constraint argument on `launch()`. `[design]`

- **Vignette note on the `y ~ .` sharp edge** — the features-as-parameter
  pattern documented in *Variants and swappability* has one hazard: `y ~ .`
  means "all non-`y` columns in whatever frame you pass." Swapping a
  20-column features table for a 25-column one silently picks up five new
  predictors — usually fine for tree learners, occasionally surprising for
  regularized linear models. This is an R formula-semantics issue, not a
  modelrunnR issue, but the introductory vignette should name it in one
  sentence so readers don't get bitten. `[readability]`
