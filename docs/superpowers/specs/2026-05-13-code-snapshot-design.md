# Code snapshot and reproducibility — layered roadmap (L0–L3)

**Status:** design, drafted 2026-05-13. **L0 is the immediate work; L1–L3 are sequenced follow-ons with sketches, not finished designs.** Each later layer will get its own spec when its turn comes; this doc exists so the order is recorded and the layers are scoped relative to each other.
**Scope:** Move modelrunnR from "we hash code and stamp the run with git/session telemetry" to "a run is independently reconstructible." Today `code_hash` is identity-only (you can detect change but cannot recover bytes); `git_info` is a pointer (fails on dirty/untracked); `session_info` is descriptive (not a restorable lockfile). This spec lays four layers on top of that scaffolding, in execution order.
**Depends on:** existing hash machinery (`R/hash_code.R`, `R/hash_file.R`, `R/hash_artifact.R`), run-row writers (`R/recording.R`, `R/launch_one.R`, `R/launch_sql.R`), git/session capture (`R/git_info.R`, `R/session_info.R`), DuckDB backend (`R/backend_duckdb.R`, `R/schema.R`).

## The problem this addresses

Three distinct concerns are entangled in the current code:

1. **Identity** — "did this code change?" `code_hash` handles this and stays.
2. **Provenance** — "what *was* the code/env at run time?" Currently captured as git sha + session info; neither is recoverable on its own.
3. **Replay** — "can I rerun this exact run elsewhere?" Not possible today.
4. **Portability** — "give me a bundle to hand off." Builds on replay.

The "scattered hashing" feeling is really that #1 is built and #2–#4 are gestured at without a clean story. This spec proposes one mental model: **a run records bytes that let it be replayed** — with progressively heavier guarantees per layer.

Prior art guiding the design: `targets` (input/code hashing for dependency tracking, leans on git for source), `renv` (lockfile semantics for R environments), MLflow (per-run code snapshot + git sha + env + metrics), and the "research compendium" pattern (Marwick et al.: source + lockfile + Dockerfile in one folder).

## Layer ordering — execute in this order

L0 → L1 → L2 → L3. Each layer is independently useful, additive on the previous, and can ship as its own release. The non-DuckDB backend track is orthogonal and not blocked by this work, but L0 finalizes the shape of one more table the backend interface must implement, so doing L0 before freezing that interface is preferable.

### L0 — Source snapshot (content-addressed)

**Goal:** `run_id → recoverable source bytes`. The script and helper files that produced a run can be reconstituted from the store alone, no git required.

**Design sketch:**

- New DuckDB table `_mr_code` keyed by `code_hash`, columns: `code_hash TEXT PRIMARY KEY`, `script_path TEXT`, `script_bytes BLOB`, `helper_paths JSON` (array), `helper_bytes JSON` (object mapping path → BLOB, or a sidecar `_mr_code_helpers` join table — decide during implementation), `inline BOOLEAN` (TRUE for `launch({...})`), `recorded_at TIMESTAMP`.
- Write path: at the point `code_hash` is computed in `R/hash_code.R` callers (`R/launch_one.R`, `R/launch_sql.R`, inline launches), upsert into `_mr_code` if the hash is novel. Idempotent: identical `code_hash` → no-op insert.
- Read path: new internal `.mr_load_code(code_hash) -> list(script = raw, helpers = list(path = raw))`. No public export in L0.
- Inline mode: `script_path` is `NA` and `script_bytes` is the deparsed expression's bytes (the same bytes that already feed `.mr_code_hash_inline`).
- SQL launches: store the rendered SQL body bytes (same source feeding the SQL `code_hash`). Treat `script_path` as the `.sql` file when one exists, otherwise NA.
- Pruning: `prune()` already cascades by run; extend to also drop `_mr_code` rows whose `code_hash` is no longer referenced by any `_mr_runs` row (garbage-collect orphans).

**Invariants engaged:**

- Invariant 4 (schema migrations append-only): the change is purely additive — a new table plus a new column on `_mr_runs` is not required if we key by `code_hash` (already on `_mr_runs`).
- Invariant 5 (exported API): no exports change in L0. Public consumption of `_mr_code` waits for L3.

**Resolved 2026-05-13:**

- **Helper storage layout:** separate `_mr_code_helpers` table with `(code_hash, helper_path, helper_hash, helper_bytes)`, joined on `code_hash`. Dedupes helpers shared across runs; helper-level lookups stay cheap. `_mr_code` itself stores `(code_hash, script_path, script_bytes, inline, recorded_at)` and does not nest helper bytes.
- **Write failure mode:** block the launch. L0 is a contract, not telemetry. If the source can't be snapshotted, the run is incomplete in the new mental model — better to surface the storage problem than record a run that promises recoverable source it doesn't have. Surface a clear error from `launch()` with the underlying DB error attached.

**Open questions (deferred):**

- Compression of `script_bytes` (DuckDB stores BLOBs uncompressed; gzip in-R before insert vs. trust DuckDB's page compression vs. leave raw). Defer until storage size becomes a real concern; ship raw first.
- **Garbage collection of orphan `_mr_code` / `_mr_code_helpers` rows.** Punted 2026-05-13 — initial L0 implementation does not GC. Orphans aren't harmful (just disk usage); decide policy (automatic on `prune()` vs explicit `prune(gc = TRUE)` vs separate `prune_code()`) before v0.2 or once a user hits real disk pressure. Tracked in TODO.

**Done when:** any `run_id` in `_mr_runs` can be passed to a (yet-unexported) `.mr_load_code()` and yield the script + helper bytes that produced it; pruning cleans up orphans; `R CMD check` clean.

### L1 — Environment lockfile (per-run renv snapshot)

**Goal:** restore the R package environment a run executed in.

**Sketch (full design later):**

- On launch, generate a per-run `renv.lock` (or equivalent JSON) via `renv::snapshot(lockfile = tempfile(), type = "all")` — but do not *manage* the user's renv project, only capture state. If `renv` is not installed, fall back to a richer `installed.packages()` snapshot (name, version, source, sha if from a remote) so L1 still produces something useful without forcing the dep.
- Store as JSON column on `_mr_runs` (most likely), or in a content-addressed `_mr_envs` table keyed by hash of the lockfile content (deduplicates across runs that share an env).
- Adds `renv` to `Suggests:`, not `Imports:` — invariant 6 (no new `Imports:` without ASK) is respected.
- Cross-language note: L1 covers R. Python steps (when the python-step spec lands) need their own `requirements.txt` / `pyproject.toml` capture; that's a parallel concern not blocked by L1.

**Open questions:**

- Lockfile dedup vs. inline storage (the `_mr_envs` table option) — pays off for sweeps where 100 runs share a lockfile.
- Should the lockfile capture be lazy (compute once per session and reuse if env hasn't changed) for sweep performance? `renv::snapshot()` is not free.
- How to surface restore: a user-facing `mr_restore_env(run_id)` that calls `renv::restore()` is the obvious shape, but ties us to renv. Maybe just expose the lockfile via accessor and let the user decide.

### L2 — Git-strict mode (opt-in, alternative path to L0)

**Goal:** a power-user mode that delegates source provenance to git instead of `_mr_code`, with strict guarantees.

**Sketch (full design later):**

- `launch(..., strict = TRUE)` (or a session-level option). Refuses to run on a dirty working tree, or — softer variant — auto-commits the dirty state to a separate `refs/mr/wip/<run_id>` ref before launch (MLflow's pattern).
- When strict mode is on, `_mr_code` writes can be skipped (sha + repo URL on the run row is sufficient pointer; L3 export can clone-and-checkout instead of materializing bytes).
- Probably *not* the default. The north star's "Other User" is a data scientist with ad-hoc scripts whose workflow is precisely the thing "must commit first" friction kills. Strict mode is for the user who has matured past that and wants the lighter on-disk footprint.

**Open questions:**

- Untracked files (e.g., a script that was never `git add`-ed) — `strict = TRUE` should refuse, or auto-commit-to-WIP-ref and warn?
- Multi-repo: helpers loaded from outside the repo root. Capture as foreign refs? Fall back to L0 for those? Document as unsupported?
- Interaction with non-git projects: does strict mode require a repo, or does it fall back to L0?

### L3 — Export (compendium bundle)

**Goal:** `mr_export(run_id, path)` produces a standalone, hand-offable bundle.

**Sketch (full design later):**

- Bundle structure (research-compendium-ish): `script.R` (or whatever the original was), `helpers/`, `renv.lock`, `inputs/` (content-addressed input blobs, or a `references.json` pointing at remote-addressable inputs), `mr_replay.R` (a small script that `renv::restore()`s then sources the script with stowed inputs faked into place), and a `manifest.json` describing the run.
- Two input modes: **embed** (copy input bytes into the bundle — large but standalone) and **reference** (record hashes only — small but requires the receiver to have access to the input source).
- Out of scope: Docker image generation. `repo2docker`-style image building is a future stretch goal; L3 produces a folder/tarball.
- Optional: an `mr_import(bundle_path)` inverse that loads the bundle's run row into a local DuckDB so the run shows up in `runs()` on the receiver's machine.

**Open questions:**

- Cross-platform replay: an R 4.5 / Linux run replayed on R 4.6 / macOS — what's the failure mode and is there a contract about it?
- Outputs: include them in the bundle, or only inputs + code (recipient re-runs to regenerate)? Probably "both, user picks."
- Multi-run export: `mr_export_pipeline(run_ids)` for a whole DAG of runs. Likely yes; deferred.

## Non-goals (across all layers)

- **Replace `targets` / `drake`.** modelrunnR is not a pipeline DAG executor; it's a run recorder. Reproducibility here means "this run can be re-executed in isolation," not "this whole DAG can be re-run with topo order."
- **Docker / Nix image generation.** Heavier and a different audience.
- **Capturing the user's whole filesystem state.** `_mr_code` captures the script and tracked helpers, not arbitrary files the script might read via `read.csv("../../somewhere.csv")`. Inputs to runs already flow through `grab()` / `external_inputs` and are content-addressed there; the reproducibility story relies on users routing data through those channels.
- **Backwards-compat shims for runs recorded before L0.** Old runs won't have `_mr_code` entries; `.mr_load_code(old_run_id)` returns NA. Don't paper over this.

## Sequencing / status

- **L0:** ready to design in detail; spec out the table layout (helper storage choice, BLOB vs. join table) and the "block vs. warn on write failure" question, then implement.
- **L1:** blocked behind L0 landing — not technically, but L0 sets the precedent for "where per-run content-addressed metadata lives."
- **L2:** blocked behind L0 landing. Strict mode is most useful when L0 exists as the default it overrides.
- **L3:** blocked behind L0 and L1. Bundle has nothing to package until both layers exist.

When L0 lands, write the L1 spec. Don't pre-design L1/L2/L3 in detail beyond what's above — those sketches will drift if implementation of L0 reshapes assumptions.

## Cross-references

- `north_star.md` — the "tracked code itself that ran" line in §1 (Me) maps onto L0; the "data scientist's ad-hoc scripts" in §2 (Other User) is why L2 stays opt-in.
- `framework.md` invariant 4 (schema migrations append-only) — every layer here adds tables/columns; none renames or drops.
- `R/hash_code.R`, `R/git_info.R`, `R/session_info.R` — the existing pieces this builds on rather than replaces.
- `docs/superpowers/specs/2026-04-26-python-step-design.md` — L1's R-only env capture is parallel to a future Python env capture, which the python-step spec will eventually need to address.
