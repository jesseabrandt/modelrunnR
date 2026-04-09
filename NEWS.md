# modelrunnR 0.0.0.9000

## Bug fixes

* `prune_versions()` now combines `keep`, `keep_latest`, and `older_than` as a union of prune masks, matching the long-standing docstring. Passing `keep_latest = TRUE` together with `keep` is an error (overlapping intent).
* Nested `launch()` calls are now detected and error rather than silently clobbering the outer launch's recording, helpers, and pins state.
* Env-var external inputs that remain unchanged no longer incorrectly report stale: the previous implementation compared a JSON-roundtripped `NULL` hash (from an unset env var) against a fresh `NA_character_`, which always mismatched.
* `stow()` and `prune_versions()` now wrap physical writes and metadata updates in DuckDB transactions. A crash mid-write can no longer leave orphaned physical tables or stale `_mr_versions` rows.
* `prune_versions()` protection is now keyed on `(logical_name, content_hash)` pairs rather than `content_hash` alone, so two different logical names sharing a hash cannot cross-protect each other.
* `grab(from_run = ...)` no longer crashes when a run row has `NA` or empty `outputs` JSON.
* `grab(as_of = "...")` now parses string arguments as UTC (to match DuckDB's timezone-naive TIMESTAMP columns), so the same string produces the same version regardless of the session's `TZ`.
* Pruning all versions of a logical name now drops the corresponding DuckDB view, eliminating dangling pointers to dropped physical tables.

## New features

* `_mr_versions` now carries a `UNIQUE INDEX` on `(logical_name, content_hash)` as belt-and-suspenders protection against duplicate rows. **Caveat**: on connect, `.mr_migrate_versions()` runs `CREATE UNIQUE INDEX IF NOT EXISTS`, which will error loudly if a pre-existing `.duckdb` happens to contain duplicate `(logical_name, content_hash)` rows (e.g. from hand-editing). In normal single-writer operation this cannot happen, but if it does, resolve by deduplicating the table manually before reopening the DB.
* `stow()` emits a warning when a data frame has non-default row names, since DBI's backend does not persist them.
* Staleness checks now distinguish `code_unknown` (pre-migration runs that predate `code_hash` tracking) from `code` (actual mismatch). **Users upgrading an existing `.duckdb` may see a one-time `code_unknown` advisory** on the next run after upgrade. Subsequent runs record a real `code_hash` and return to reporting `fresh`.

## Documentation

* `R/backend_duckdb.R` comments now document the type-sensitive hashing contract and the ~0.03%-at-100M-rows 64-bit HASH collision caveat.
* `docs/plan.md` Slice 3 section rewritten to describe the actually shipped `STRING_AGG`+`MD5` algorithm, with a note on why the initially sketched `SUM`/`XOR` scheme was rejected (XOR loses multiplicity; SUM wraps).
