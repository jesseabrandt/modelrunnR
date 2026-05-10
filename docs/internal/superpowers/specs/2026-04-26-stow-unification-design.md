# Unified `stow()` — file sources as tagged values, versioned frames

**Status:** design, drafted 2026-04-26
**Scope:** Collapse `ingest()` into `stow()` via type dispatch. Add a tagged-path value `mr_file(path)` that routes through the existing file-ingest code path. Add `shape = "versioned"` as an opt-in for in-memory data frames so they can be stored versioned-shape rather than the append-shape default. Deprecate the `ingest()` export to a thin shim that delegates to `stow()`. No schema change. No new `Imports`.
**Depends on:** existing `stow()` type dispatch (R/stow.R:57), existing file-to-DuckDB ingestion internals (R/ingest.R, `.mr_ingest_file_to_table`), existing `.mr_stow_table` shared by ingest and frame-versioned writes.

**Non-goals / deferred:**

- No change to `grab(source = path)` — its read-or-ingest behavior stays as-is. Bringing `grab` into the `mr_file()` vocabulary (e.g. `grab(mr_file(path), name)`) is a follow-up; it lives next to the existing `source =` kwarg, not in place of it. Logged as a TODO.
- No new file-format support. `mr_file()` accepts what `ingest()` accepts today: `.csv`, `.tsv`, `.parquet`. New formats are out of scope.
- No `stow_file()` or other file-specific export. Internal dispatch handles the file case; users only learn `stow()` and `mr_file()`.
- No removal of `ingest()`. The export stays for one cycle as a `.Deprecated()` shim. Hard removal is a separate, future change (invariant 5).
- No changes to append-shape `stow(df, name)` default behavior. Frames default append; `shape = "versioned"` is a per-call opt-in.
- No new connection / config ceremony — connection resolution stays implicit per current convention.

## Motivation

Two friction points compound into one design problem:

1. **Verb mismatch.** `stow()` and `grab()` form a clean pair (put away / fetch back). `ingest()` is a third verb with a metaphor that doesn't compose with `grab` (digest vs. grab) and a separate signature shape (`name` first, path-only). Users — and the agent operating in `mi_forests` — reach for `ingest()` thinking "I want this stored as a versioned input," not "I want to digest a file." The verb disguises what's actually a stow-with-versioned-shape.
2. **Path-only file constraint.** `ingest()` accepts a file path and only a file path. A project that builds its source dataset in R has to write a parquet to disk, point `ingest()` at it, then delete the file — a ~7-line detour for a one-line concept. Surfaced as `TODO.md` item "In-memory frame → versioned source should be a one-liner" (2026-04-25).

Both fall out of the same root: there is no single mental model for "register this thing as a named input." `stow()` already has type-dispatched semantics for non-frame R objects (everything except a `data.frame` or `tbl_lazy` lands versioned-shape today — see R/stow.R:80–89); the missing pieces are (a) a tagged value that lets a file path participate in the same dispatch, and (b) a flag that lets a frame opt into versioned shape without a file detour.

This is consistent with the **shape-invisibility principle** stated in the 2026-04-22 append-mode spec rev 3: *the user shouldn't need to know which shape backs a name to decide which function to call.* Today they do — they reach for `ingest()` specifically when they want versioned-shape on tabular input. After this change, the verb is `stow()` regardless; the value type and an optional shape kwarg pick the path.

## Target usage

```r
library(modelrunnR)

# Existing (unchanged) ----------------------------------------------------

# Non-frame R object → versioned artifact (already works today)
stow(my_model, "fit")

# Frame inside a tracked launch → append-shape (already works today)
launch_code("fit_model", quote({
  metrics <- run_one_model(grab("training"))
  stow(metrics, "metrics")
}))

# New ---------------------------------------------------------------------

# File source — replaces ingest(). value-first, name second.
stow(mr_file("data/training.parquet"), "training")

# In-memory frame as versioned input — no file detour. Frames default
# append; the kwarg opts into versioned-shape for this call only.
df <- build_training_data()
stow(df, "training", shape = "versioned")

# Read side is unchanged.
grab("training")
grab("metrics", run = "all")
```

The vignette story becomes: "you have one verb (`stow`) for handing a value to the store; what kind of value you hand it picks the storage shape." Files are a value type (`mr_file`); frames are a value type with an extra knob.

## Behavior

### 1. `mr_file()` constructor

```r
mr_file <- function(path) {
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) {
    stop("mr_file(): `path` must be a length-1 non-empty character.", call. = FALSE)
  }
  structure(path, class = c("mr_file", "character"))
}
```

- **Lazy validation.** `mr_file()` does *not* check `file.exists()` at construction time. Existence is checked at the stow site, matching `ingest()`'s current behavior (R/ingest.R:33–35) and allowing `mr_file()` values to be carried in lists, mapped over, etc., without spurious errors when the file isn't yet on disk.
- **Print method** (cosmetic, low priority): `print.mr_file` renders `<mr_file: data/training.parquet>` instead of the bare path-with-attributes default. Useful when `mr_file()` values appear in a console pipeline.
- **Format method.** Tabular contexts (e.g. tibble printing) should fall back to the underlying character. Inheriting from `character` covers this for free.

`mr_file` lives in `R/mr_file.R`. Exported.

### 2. `stow()` dispatch — new branch

`stow()` keeps its value-first signature. Dispatch table after this change (R/stow.R:80–89 expands):

| Value class                  | Path                                  | Shape       |
|------------------------------|---------------------------------------|-------------|
| `mr_file`                    | `.mr_stow_file()` (file → DuckDB)    | versioned   |
| `tbl_lazy`                   | `.mr_append_write_lazy()`            | append      |
| `data.frame` + `shape="versioned"` | `.mr_stow_table()`             | versioned   |
| `data.frame`                 | `.mr_append_write_frame()`            | append      |
| anything else                | `.mr_stow_artifact()`                 | versioned   |

Order matters: `mr_file` is checked first (it inherits from `character`, which is otherwise an "anything else" → artifact case). `tbl_lazy` is checked before `data.frame` because some lazy tbl classes also inherit from `data.frame`.

The new signature:

```r
stow <- function(value, name, shape = NULL) { ... }
```

`shape` is `NULL` by default and only meaningful when `value` is a `data.frame` or `tbl_lazy`:

- `shape = NULL` → existing default (frames append-shape; lazy tbls append-shape).
- `shape = "versioned"` → routes the frame through `.mr_stow_table()` (the same internal that ingest uses post-staging).
- `shape = "append"` → explicit version of the default. No-op for frames; documented for symmetry.
- Any other value → error: `stow(): shape must be NULL, "versioned", or "append".`
- `shape` non-NULL with a non-tabular `value` → error: `stow(): shape is only meaningful for data frames and lazy tbls; got <class>.` (Loud rather than silent so callers don't think they got versioned-shape on an artifact when artifacts are already versioned.)
- `shape` non-NULL with `value` of class `mr_file` → error: `stow(): mr_file values are always versioned; drop the shape argument.` (The combination would imply the user thinks `shape` controls the file path, which it doesn't.)

### 3. `.mr_stow_file()` — new internal

Implements what `ingest()` does today, factored to take an `mr_file` value. Pseudocode:

```r
.mr_stow_file <- function(value, name) {
  path <- unclass(value)  # back to plain character
  if (!file.exists(path)) {
    stop(sprintf("stow(mr_file(...)): file not found: %s", path), call. = FALSE)
  }
  con <- .mr_get_connection()
  staging <- .mr_random_staging_name("ingest")
  .mr_ingest_file_to_table(con, path, staging)
  on.exit(try(.mr_drop_table(con, staging), silent = TRUE), add = TRUE)

  content_hash <- .mr_hash_duckdb_table(con, staging)
  src_hash <- .mr_file_hash(path)
  src_uri  <- normalizePath(path, mustWork = TRUE)

  # Atomic transaction: rename staging → physical_name, upsert
  # _mr_versions row (with source_uri/source_hash), refresh latest view.
  # Mirrors the current ingest() body (R/ingest.R:62–98) — shape of the
  # steps is the same as .mr_stow_table()'s, but the materialization
  # primitive differs (ALTER TABLE RENAME, since data is already a
  # DuckDB table, vs. .mr_table_write() which writes a frame from R).
  .mr_persist_versioned_table_from_staging(
    con, name, staging, content_hash,
    src_uri = src_uri, src_hash = src_hash
  )
}
```

The intent is to **move, not duplicate**, the current `ingest()` body. Today's body does: stage file → hash staging → physical-name → atomic (rename + `_mr_versions` upsert + view refresh) → `_mr_record_write`. After this change, that body becomes `.mr_stow_file()`, and `ingest()` is a deprecation shim that calls `stow(mr_file(source), name)`.

Whether `.mr_stow_file()` and `.mr_stow_table()` factor out a common `.mr_persist_versioned_table*` helper or remain near-parallel functions is an implementation choice; both end up writing the same row shape to `_mr_versions` and refreshing the same view, so the two callers must stay aligned regardless.

### 4. Frame-as-versioned (`shape = "versioned"`)

Routes to the existing `.mr_stow_table()` (R/stow.R:98–154). That internal already:

- hashes the frame via `.mr_hash_frame()`,
- assigns a content-addressed `physical_name`,
- inserts/updates the `_mr_versions` row,
- atomic write + view refresh,
- records the write on the run row (if inside a launch),
- emits the version-count warning.

No new internal needed; just route the frame to it.

**Hash basis vs. file ingest.** `.mr_hash_frame()` and `.mr_hash_duckdb_table()` use different bases (R-side serialize vs. DuckDB-side). A frame stowed versioned and the same data ingested from a CSV will produce different content hashes. This matches the existing documented behavior in the "Hashing contract" section of `stow()` (R/stow.R:40–49) and is not new with this change. Surface in roxygen.

**No `_mr_versions` source columns for in-memory.** When a frame is stowed versioned, `src_uri` and `src_hash` are NULL on the version row. Reading those columns on an in-memory-versioned name returns NULL — same as the artifact path today. `grab(name, source = path)` idempotence still keys on the file's hash, so a name that's been written from both paths (in-memory and file) keeps multiple versions and `grab(source = path)` re-uses the file-derived version when its hash matches. This is the existing semantics, unchanged.

### 5. `ingest()` deprecation

```r
#' @export
ingest <- function(name, source) {
  .Deprecated(
    new = "stow",
    msg = "ingest() is deprecated; use `stow(mr_file(source), name)` instead."
  )
  stow(mr_file(source), name)
}
```

- Stays exported (invariant 5: changing the export list requires ASK; the user authorized deprecation in 2026-04-26 conversation, but kept the symbol for one cycle).
- Argument order **does not change** — `ingest("training", path)` continues to work, just with a deprecation warning.
- The `.Deprecated()` warning fires once per session per call site (R's default behavior).
- Scheduled hard-removal: not in this spec. Logged as a TODO ("Remove `ingest()` after one release cycle and `final_practicum` migration").

### 6. Vignette and doc updates

- `vignettes/getting-started.Rmd` currently introduces the store via `ingest()` (file path) — see lines 41–55 of the current vignette. Update to use `stow(mr_file(path), name)` as the primary, with a note that "`ingest()` is the older name and still works but is deprecated."
- `vignettes/lazy-data.Rmd`, `vignettes/batch-launches.Rmd`, `vignettes/nested-sweeps.Rmd` — grep for `ingest(`; update any reference. (Per memory `feedback_vignettes.md`: vignettes encode approved API shape, so these updates *are* the API shape change, not papering over breakage.)
- `R/stow.R` roxygen — add the file-source dispatch case and the `shape` argument under `@param`.
- `R/ingest.R` roxygen — mark `@description` deprecated, point to `stow()`.
- `R/grab.R` roxygen — `grab(source = path)` mention of `ingest()` becomes "implicit `stow(mr_file(path), name)`."

### 7. TODO closure

This change closes (or partially closes) the following `TODO.md` items:

- **"In-memory frame → versioned source should be a one-liner"** (Surfaced 2026-04-25): closed by `shape = "versioned"`.
- **AU-Catalog README ordering note** (notes/AU-Catalog-findings.md:120, "Getting Started" core handful): the core handful shrinks from `launch / stow / grab / ingest / versions` to `launch / stow / grab / versions` plus `mr_file` as a value constructor. Cleaner narrative.

Not closed (logged as new TODOs):

- Bringing `grab(source = path)` into the `mr_file()` vocabulary (`grab(mr_file(path), name)`).
- Hard-removing `ingest()` after the deprecation cycle.

## Internal API sketch

Files touched:

- `R/stow.R` — extend dispatch in `stow()` (R/stow.R:57); add `shape` argument; add error messages for invalid `shape` combinations.
- `R/ingest.R` — body becomes a `.Deprecated()` shim that delegates to `stow(mr_file(source), name)`. The current ingest body (stage → hash → persist) moves to `.mr_stow_file()` in `R/stow_file.R` (or `R/stow.R` if compact enough).
- `R/mr_file.R` — new file. `mr_file()` constructor + `print.mr_file()` method.
- `NAMESPACE` — add `export(mr_file)` and `S3method(print, mr_file)`. `export(ingest)` stays.
- `man/` — regenerate via `devtools::document()`.

No new `Imports`. `mr_file()` is pure base R; the print method uses base.

## Testing

New tests in `tests/testthat/`:

- `test-mr_file.R` — constructor validation (length-1 character, nzchar); `inherits(mr_file("x"), c("mr_file", "character"))`; print method renders the expected form.
- `test-stow-file.R` — `stow(mr_file(csv_path), "x")` round-trips identically to `ingest("x", csv_path)`; same content hash; same `_mr_versions` row shape; `grab("x") |> collect()` returns identical data.
- `test-stow-versioned-frame.R` — `stow(df, "x", shape = "versioned")` lands in `_mr_versions` (versioned-shape), not in append-shape; subsequent `grab("x")` returns the frame; re-stowing identical content is a no-op (last_seen update only); two distinct frames produce two version rows.
- `test-stow-shape-validation.R` — `stow(model, "x", shape = "versioned")` errors; `stow(mr_file(p), "x", shape = "versioned")` errors; `stow(df, "x", shape = "garbage")` errors.
- `test-ingest-deprecation.R` — `ingest("x", path)` emits a deprecation warning AND succeeds (use `expect_warning(..., regex = "deprecated")`).

Existing tests in `test-ingest.R`: keep, since the deprecation shim must still produce identical results. Mark with a note that they implicitly cover the shim path; the new `test-stow-file.R` covers the value-first path.

## Migration / breakage

- **`final_practicum`** (invariant 1): currently uses `ingest()` per its own scripts. The deprecation shim keeps it working with a per-session warning. No code changes required there before this lands. Surface in commit message.
- **`mi_forests`** and **`AU-Catalog`** (sibling projects): same — keep working via the shim. The "in-memory frame → versioned source" friction is fixed for both.
- **DuckDB stores in the wild** (invariant 4): no schema change. Existing `_mr_versions` rows produced by `ingest()` are byte-identical to what `stow(mr_file(...))` would produce for the same file. No migration needed.

## Open questions

None remaining at design time. Resolved during brainstorm 2026-04-26:

- **`shape = "versioned"` vs `versioned = TRUE`:** chose `shape =` to match existing internal vocabulary and leave room for a third shape if one ever lands.
- **Export `stow_file` as a sibling:** rejected. Internal-only. One verb (`stow`) for users.
- **`source =` kwarg overload (option C from brainstorm):** rejected — overloads `source`'s type semantics ambiguously between path and frame.
- **First-arg flip (option 2 from brainstorm):** rejected — `stow(value, name)` stays uniform across all value types, including `mr_file`.
