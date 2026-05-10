# next-version notes

Working notes from the post-v0.1.0 direction conversation. Not a spec
— captures decisions, open questions, and tensions to resolve before
writing reqs and editing the north star.

## Headline reframe

Two moves, mutually reinforcing:

1. **Make storage pluggable.** DuckDB stops being mandatory. Storing
   info is non-negotiable; *how* it's stored is configurable. Package
   functions dispatch through a backend interface.
2. **Lead with `launch()`, not grab/stow.** The pitch shifts from
   "redefine all your inputs and outputs through this package" to
   "wrap your scripts so you can track what you ran." `grab`/`stow`
   become the optional next step, not the entry tax.

The reframes reinforce each other: if `launch()` is the entry point
and the user doesn't have to move their data, the bar to adoption
drops a lot.

## What's pluggable

- The data store: where `stow()` writes, where `grab()` reads from.
- The run log: `_mr_runs` itself can live somewhere other than a
  DuckDB file (e.g. a `runs.csv` on disk).

Both. CSV-mode runs is a CSV.

## Architecture sketch

A storage-backend abstraction. Package code (`launch`, `grab`,
`stow`, `runs`, `versions`, `prune`, etc.) goes through a dispatcher
rather than hand-rolling DuckDB SQL.

- Default backend = `duckdb` (today's behavior, no migration shock).
- New backend = `files` (folder of files on disk).
- More backends possible later (sqlite, postgres) but not in scope
  for the next version.

User-visible config: TBD — one option flag (`modelrunnR.backend =
"duckdb" | "files"`), or a richer setup function
(`use_files_backend(path = ".modelrunnR/")`). To decide.

## Backend interface — minimum primitive set

Rough first cut. The contract has to be high-level enough that a
non-SQL backend can implement it.

- `record_run(row)` — append a run record.
- `read_runs(filter)` — return runs as a tibble.
- `write_versioned(name, value, hash, kind)` — store a versioned
  artifact / table.
- `read_versioned(name, hash)` — fetch a specific version.
- `append_chunk(name, df, run_id, hash)` — append-shape stow.
- `read_append(name, run_filter)` — read append-shape stow,
  optionally scoped to a run.
- `list_versions(name)`, `list_appends(name)` — for `versions()`.
- A few prune / drop ops.

SQL-flavored features live *above* this interface, gated to backends
that opt in.

## Files backend specifics

- `runs.csv` — the run log. Human-readable, diffable.
- Stowed tabular values → **parquet** by default. Types preserved
  (factors, dates, integer vs numeric), small files, arrow can read
  lazily later if we ever want to revisit lazy-tbl on this backend.
- If the user doesn't have `arrow` installed, fall back to CSV with
  a one-time message about type loss. Means `arrow` stays in
  `Suggests`, not `Imports` (invariant 6 friendly).
- Stowed non-tabular artifacts → `qs2` files (already a dep).
- Versions metadata → a small CSV alongside, or co-located with each
  versioned artifact. To decide.

So "files mode" is really "files of mixed type": CSV for logs,
parquet for tables, qs2 for artifacts. Naming TBD — could be
`backend = "files"` with parquet preferred, or split into
`"parquet"` / `"csv"` modes. Mixed-file mode is probably the right
abstraction (one mode that picks the best on-disk shape per kind).

## Feature gating, not feature parity

The files backend won't have:

- Lazy `dbplyr` tbls from `grab()` — eager tibbles only.
- SQL launches (`launch("x.sql")`, `mr_sql()`).
- `mr_con()` — there's no connection.
- View-mode stows / `materialize = TRUE`.
- Maybe: `external_inputs` against DuckDB-resident sources (env vars
  and files still work).

These error with a clear "this feature requires a SQL-capable
backend (e.g. duckdb)" rather than half-working. Honest > magical.

Feature parity *is* required for:

- Run tracking, code hashing, staleness, label/variant inheritance.
- `versions()` / `runs()` / `variants()` (eager).
- `grab` / `stow` round-trip (eager).
- `prune` / `prune_variants`.
- `queue()` (the queued-row state can live anywhere).

## Migration as a first-class feature

A `migrate_backend(from, to)` helper that walks every run row and
stowed value through the interface and writes them to the new
backend. If the abstraction is right, this is one loop. If not, the
abstraction is wrong — the helper is the cleanest test of the
interface.

Probably v0.2 or later, but the v0.next interface design has to
permit it.

## Pitch / docs implications

- README "Example" leads with bare `launch({ ... })` — no I/O
  declared, just tracking.
- Vignette ordering: `launch()` first, then "if you want
  input/output tracking, here's `grab`/`stow`," then "if you want to
  swap inputs/outputs across runs, here's rebind / variants."
- Getting-started gets reordered or rewritten.
- The grab/stow swap-out story remains the migration path *into* a
  database setup later — that's still a real selling point, just
  not the headline.

## Minimum to try `launch()`

Already friendly: the package auto-creates the DuckDB file. Files
backend would be similarly friendly — first `launch()` creates
`./.modelrunnR/` with `runs.csv`. Zero setup either way. No urgent
"first-run is too heavy" problem.

In-memory log is rejected — log must be persistent.

## Open questions for reqs

- Config surface: option flag vs setup function vs both.
- Files backend layout — flat folder or subdirs per kind
  (`runs.csv`, `versions/`, `appends/`, `artifacts/`)?
- Whether `arrow` becomes Suggests with a graceful fallback to CSV
  for tables, or whether files-mode-without-arrow is unsupported.
- What does `versions()` return for files-mode chunked appends —
  same shape, just eager?
- Default for *new* projects: stay duckdb, or files?
  (Decision today: stay duckdb. Revisit when files-mode is real.)
- Migration helper scope: bidirectional (duckdb ↔ files) or
  one-way?

## Decisions captured

- Both data store and run log are pluggable.
- Default stays DuckDB for now.
- Lazy tbls are DuckDB-only; other modes are eager.
- Logical names always; backend resolves them.
- Parquet is the natural stow target on disk; CSV fallback if
  arrow not installed.
- Run log must be persistent (no in-memory mode).
- Feature gating, not parity — SQL-shaped features stay
  duckdb-only.
- Migration helper is a thing.
