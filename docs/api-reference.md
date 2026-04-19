# modelrunnR — API reference (AI-optimized)

Dense, structured reference for agents. Human-readable prose lives in
`README.md`, `vignettes/getting-started.Rmd`, and `docs/design.md`.

## 1. Mental model in one paragraph

modelrunnR tracks R code runs in a single DuckDB file. Two primitives —
`stow(value, name)` (write) and `grab(name)` (read) — move values into and
out of a content-addressed store keyed on a **logical name**. Wrap code
in `launch({ ... })` or `launch("file.R")` to record a run row tying
inputs, outputs, code bytes, external inputs, duration, and status
together. Reruns of an unchanged block under the same **label** skip
evaluation entirely (`skipped_fresh`). A label marks a *pipeline
identity* that can accumulate history across edits; a **version** is a
specific `(logical_name, content_hash)` under that name.

## 2. Core concepts (exact definitions)

| Concept | What it is | Keyed by |
|---|---|---|
| **logical name** | A user-chosen string naming a value in the store. Namespace is flat and shared between tables and artifacts. | string |
| **version** | One content-addressed snapshot of a logical name. | `(logical_name, content_hash)` — unique index |
| **content hash** | `sha256`-style hash of the stored bytes (frame rendered by DuckDB for tables; `qs2`-serialized for artifacts). Type-sensitive: int vs double columns hash differently. | derived |
| **step** | Pipeline identity string. For files: normalized absolute path. For inline: `"<inline:<12-hex>>"` derived from deparsed expression bytes. Editing inline code creates a new step. | string |
| **run** | One `launch()` invocation. Row in `_mr_runs`. Always written, even on error / skip. | `run_id` |
| **label** (a.k.a. `variant_label`) | User tag marking a run as belonging to a named pipeline thread. Multiple steps can share a label (e.g. across inline edits). Empty/whitespace labels rejected. | string |
| **kind** | `"table"` (data.frame → DuckDB table + view) or `"artifact"` (everything else → `qs2`-serialized BLOB or file). | enum |

## 3. Exported surface (16 symbols)

### 3.1 Write / read / ingest

```r
stow(value, name)             # value-first
grab(name,
     version = NULL,           # content hash
     from_run = NULL,          # run_id
     as_of = NULL,             # POSIXct or "YYYY-MM-DD..." (parsed UTC)
     source = NULL,            # CSV/Parquet path; triggers implicit ingest()
     variant = NULL)           # label; picks latest hash produced under it
ingest(name, source)          # CSV/TSV/Parquet → stow() + record source_uri/hash
```

- Exactly one of `version` / `from_run` / `as_of` / `variant` may be
  passed. Multiple → error. `source` is orthogonal (idempotent cache).
- `stow(value, name)` dispatches on `is.data.frame(value)`. Tables and
  artifacts share one namespace — `stow("x", df)` after
  `stow("x", model)` errors (`.mr_guard_namespace`).
- Artifacts < `options("modelrunnR.blob_threshold", 10 MB)` live in
  `_mr_artifacts.payload` BLOB; larger live at
  `<db_dir>/modelrunnR_artifacts/<name>__<hash16>.qs2`.
- Under `launch()`, `stow` records an output pair, `grab` records an
  input pair on the run row.
- Calling `stow()` outside `launch()` still writes a `_mr_runs` row
  tagged as an interactive write; later tracked runs that `grab()` the
  same hash get an interactive-origin warning.

### 3.2 Orchestration

```r
launch(script_path,                 # braced block, file path, or mr_label()
       rebind = NULL,               # named list; see §5
       label = NULL,                # variant label
       external_inputs = NULL,      # list(files = chr, env = chr)
       force = FALSE,               # force run even if fresh
       ...)                         # reserved; traps removed pin=/data=
launch_code(run_id, from_db = FALSE)   # recover the code a run executed
is_stale(ref)                         # ref must be mr_label() or mr_variant()
```

Dispatch inside `launch()` (in order):

1. First arg is a literal `{ ... }` → **inline mode**. Step =
   `<inline:<hash12>>` of deparsed bytes.
2. First arg is `mr_label(x)` → **relaunch mode**. Looks up most recent
   run with `variant_label == x`, re-sources the file if present, else
   runs the stored `code_body` snapshot. Label auto-inherits unless
   caller overrides. Only `mr_label()` works here; other refs error.
3. Otherwise treated as a file path (must exist).

Skip-on-fresh behavior (default since 0.0.0.9000):

- Before evaluation, `.mr_is_stale(step, variant_label)` checks code +
  declared external inputs + observed inputs against the previous run
  under the same label.
- `stale = FALSE` and `force = FALSE` and
  `options("modelrunnR.skip_if_fresh", TRUE)` ⇒ block is *not*
  evaluated. A `_mr_runs` row with `status = "skipped_fresh"` is still
  written (duration 0, empty inputs/outputs, prior `code_hash` copied).
- To see the old "advisory only" semantics: set
  `options(modelrunnR.skip_if_fresh = FALSE)`.

Auto-propagation of label: if caller didn't pass `label`, after the
block runs, modelrunnR inspects observed inputs for labeled upstreams.
If all labeled upstreams agree, the run inherits that label (timing
line notes the propagation source). Disagreement → warning, no label.

Nested launches are rejected in v0.1.

Inside a launched block, `source()` is shadowed: helper files sourced
transitively are hashed and recorded. The shadow defaults
`local = TRUE` (the launched env), unlike base `source()`. Pass
`source(x, local = FALSE)` to opt out.

Return value: one-row data frame (the `_mr_runs` row), invisibly.

### 3.3 Inspection

```r
versions(name)             # one row per (name, content_hash); adds produced_by_runs list-col
variants(script = NULL, name = NULL)   # one row per (step, label); filter
variants_unexplored(script)            # labeled upstream hashes this script never grabbed
db_path()                              # resolved DuckDB path
```

`versions()` columns: `content_hash, first_seen, last_seen, size_bytes,
produced_by_runs`.

`variants()` columns: `script, label, first_seen, last_seen, n_runs,
latest_run_id`. Note: column is called `script` but holds `step` — for
inline runs it is `<inline:...>`.

### 3.4 Pruning

```r
prune_versions(name = NULL,
               keep = NULL,
               keep_latest = FALSE,
               older_than = NULL,      # "30d", "6h", "15m", "45s"
               force = FALSE)
prune_variants(script, label, dry_run = FALSE)
```

- `prune_versions` masks combine as **UNION** of the active policies.
- Passing both `keep_latest` and `keep` is an error.
- Without `force`, versions referenced by any `_mr_runs.outputs`
  entry *and* any version produced by a labeled-variant run are
  protected; labels act as keep-this signals.
- `prune_variants` deletes only the `_mr_runs` rows. Version GC is
  left to `prune_versions`.

### 3.5 Reference constructors (`mr_*`)

```r
mr_hash(content_hash)     # address a specific version
mr_run(run_id)            # address the version an output pair of a run
mr_variant(label)         # address latest hash produced under label
mr_as_of(time)            # address latest version at-or-before time (UTC)
mr_label(label)           # address a pipeline identity (relaunch / is_stale)
```

All return `structure(list(kind, value), class = "mr_ref")`.

Where they work:

| Position | `mr_hash` | `mr_run` | `mr_variant` | `mr_as_of` | `mr_label` |
|---|---|---|---|---|---|
| `launch(rebind = list(x = ref))` | ✓ | ✓ | ✓ | ✓ | ✗ |
| `launch(ref)` (relaunch) | ✗ | ✗ | ✗ | ✗ | ✓ |
| `is_stale(ref)` | ✗ | ✗ | ✓ | ✗ | ✓ |
| `grab(..., <arg>)` uses plain strings, not refs | `version=` | `from_run=` | `variant=` | `as_of=` | — |

Mismatch rule: `mr_variant` addresses **stored content**;
`mr_label` addresses **pipeline identity**. `is_stale` requires the
latter two only.

## 4. Data model (DuckDB)

Tables created idempotently at connect by `.mr_migrate()`:

```sql
-- Every launch() produces one row, including errors and skipped_fresh.
_mr_runs(
  step, run_id, inputs, outputs, started_at, duration_ms, status,
  code_hash, external_inputs, helpers, variant_label, code_body
)
-- inputs/outputs/external_inputs/helpers are JSON TEXT columns.
-- inputs/outputs shape: '[{"name":"x","hash":"..."}, ...]'
-- external_inputs shape: '{"files":[{"path":..,"hash":..}], "env":[{"name":..,"value_hash":..}]}'
-- helpers shape: '[{"path":..,"hash":..}, ...]'

_mr_versions(
  logical_name, content_hash, physical_name, kind,
  first_seen, last_seen, size_bytes, source_uri, source_hash,
  storage_location
)
-- UNIQUE(logical_name, content_hash)
-- kind ∈ {'table','artifact'}; storage_location ∈ {'blob','file',NULL}

_mr_artifacts(physical_name PK, payload BLOB)
```

Also: one DuckDB view per live logical table name, refreshed on every
stow/prune to point at the latest `physical_name`. Direct SQL against
the logical name therefore reads the latest version.

`status` values observed: `"success"`, `"error"`, `"skipped_fresh"`,
and synthetic rows tagged `"<interactive:...>"` in `step` for REPL
writes.

## 5. `rebind` semantics

```r
launch({ ... }, rebind = list(
  training = df,                       # bare value → stowed, its hash binds
  features = mr_hash("ab12..."),       # pin to existing version
  preds    = mr_run("run_..."),        # pin to the version produced by run
  model    = mr_variant("slow"),       # pin to latest under label "slow"
  ts       = mr_as_of("2026-04-01")    # pin to that point in time
))
```

While the block runs, each `grab(name)` inside consults
`.mr_state$rebinds` first; a bound name resolves to the stored hash
without reading whatever "latest" currently is. Explicit `version=` /
`from_run=` / `as_of=` / `variant=` arguments on `grab()` still win
over the rebind.

## 6. Staleness reasons (attribute on `is_stale()` result)

- `"never_run"` — no prior run under this label.
- `"code"` — stored `code_hash` differs.
- `"input:<name>"` — observed-input hash differs from prior.
- `"external:<path>"` — declared external file's hash changed.
- `"external:env:<NAME>"` — declared env var's hash changed.

`is_stale()` returns a scalar logical with `attr(., "reasons")`.

## 7. Path resolution (`db_path()`)

1. `getOption("modelrunnR.db")` if set.
2. Walk up from `getwd()` for a project marker: `DESCRIPTION`,
   `*.Rproj`, `.git/`, `renv.lock`, `.here`. If found →
   `<root>/modelrunnR.duckdb`.
3. Else `<cwd>/modelrunnR.duckdb` **and warn**.

Artifact directory (large artifacts): `<db_dir>/modelrunnR_artifacts/`.

## 8. Options

| Option | Default | Effect |
|---|---|---|
| `modelrunnR.db` | NULL | Override DB path. |
| `modelrunnR.skip_if_fresh` | `TRUE` | Skip-on-fresh in `launch()`. |
| `modelrunnR.blob_threshold` | `10 * 1024^2` (10 MB) | Artifact BLOB-vs-file cutoff. |
| `modelrunnR.version_warn_threshold` | `20` | Warn after this many versions of one name. |

## 9. Invariants & gotchas (high signal)

- **Inline step identity is expression-hash-keyed.** Editing the body
  of a `launch({ ... })` produces a *new* step. Version history under
  a label can span multiple steps; `variants()` may return several
  rows for one label after edits.
- **Content-hash type sensitivity.** `stow(df)` where a column is
  `integer` vs `double` → different hashes → new version. CSV round
  trips via `ingest()` can trigger a false "changed" signal.
- **Row names are not persisted** for data frames (DuckDB backend).
  `stow()` warns if they're non-default.
- **Hashing contract for artifacts** is the serialized `qs2` bytes —
  not the R-object identity — so environments with differing
  addresses that serialize identically will dedup.
- **Namespace collisions across kinds error.** One name ⇒ one kind.
- **`grab()` outside `launch()` is unrecorded.** Only writes (stow)
  leave interactive breadcrumbs.
- **`mr_label()` is the only ref accepted as `launch()`'s first
  argument.** Other refs → clear error.
- **Label propagation requires agreement.** Mixed labeled upstreams
  ⇒ warning, no label attached.
- **Nested `launch()` is rejected.** The recording singletons in
  `.mr_state` don't stack yet.
- **Transactions wrap physical write + metadata row + view refresh.**
  A crash mid-stow will not leave partial state; a file artifact
  written before the transaction is cleaned up on rollback.
- **`qs2::qs_deserialize` on `grab()` of artifacts.** Treat unknown
  DuckDB files like untrusted R code; don't open arbitrary shared
  stores.
- **Run rows are written even when the user code errors.** `status`
  is `"error"` and the recorded inputs/outputs are whatever was
  captured before the throw.

## 10. Typical flows (patterns an agent can apply)

```r
# One-time: load a CSV into the store.
ingest("training", "data/train.csv")

# Iterate on a model under a label.
launch({
  training <- grab("training")
  stow(lm(y ~ ., training), "model")
}, label = "baseline")

# Re-run the labeled pipeline without retyping code.
launch(mr_label("baseline"))          # skip-on-fresh applies

# Force a rerun.
launch(mr_label("baseline"), force = TRUE)

# Branch on staleness without calling launch().
if (is_stale(mr_label("embed"))) { ... }

# Swap an input at run time.
launch({ stow(predict(grab("model"), grab("training")), "preds") },
       label = "baseline",
       rebind = list(model = mr_variant("slow")))

# Recover the exact code a run executed.
launch_code("run_20260417_...")        # disk preferred for file runs
launch_code("run_20260417_...", from_db = TRUE)  # stored snapshot

# Inspect + prune.
versions("preds")
variants(name = "preds")
prune_versions("preds", keep = 3, older_than = "30d")
prune_variants("fit.R", "experimental_v2")
```

## 11. Non-obvious dispatch/edge behavior

- `launch()` rejects legacy args `pin`, `data` with a clear error
  directing the user to `rebind`.
- `as_of` string inputs are parsed as UTC; DuckDB timestamps are
  timezone-naive, so TZ stability is deliberate.
- `variants()$script` is a step id, not necessarily a filesystem path.
- `launch_code(run_id)` prefers the current file on disk for script
  runs; pass `from_db = TRUE` to audit what the run *actually* saw.
- `prune_versions` without `force` protects labeled-variant outputs
  unconditionally; dropping a labeled variant requires
  `prune_variants()` first or `force = TRUE`.
