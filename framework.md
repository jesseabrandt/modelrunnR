# Framework — Code Database Accumulator

**North star:** [north_star.md](north_star.md)

## Invariants

1. **`R CMD check` must pass before claiming a task done.** Warnings are SURFACED, not swallowed.
2. **Schema migrations are append-only.** v0.1.0 is in the wild and users have DuckDB stores on disk; renames or drops on `_mr_runs` / `_mr_versions` / `_mr_code` / etc. are unrecoverable without ASK.
3. **No new `Imports:` dependency without ASK.** Package stays lean.

## Decision Tree

ASK/SURFACE post immediately and only block dependent work — see north-star-execute "Surface-and-continue". Collapse repeat ASKs to the principle level (one design question, not N instance questions).

```
├─ Explicit in active spec/plan?          → EXECUTE
├─ Standing invariant above?              → EXECUTE
├─ Closed decision (spec, todo, memory)?  → EXECUTE
├─ Bug in call graph, blocking task?      → EXECUTE (note in commit)
├─ Bug outside call graph?                → SURFACE (don't touch)
├─ Touches _mr_* schema non-additively?   → ASK (invariant 2)
├─ Adds a new Imports: dependency?        → ASK (invariant 3)
├─ Design decision with >1 valid answer?  → ASK
├─ Would violate an invariant?            → ASK
└─ Opportunistic cleanup, unrelated?      → QUEUE to TODO.md
```

**Test for "closed decision":** Has the user already said what the answer is, anywhere — spec, todo, memory, conversation? If yes, execute. If no, ask.

## Session Start Ritual

1. Read `north_star.md`
2. Read this framework
3. Read the active spec(s) under `docs/superpowers/specs/` if any are relevant to the work
4. Skim `TODO.md` and recent commits (`git log --oneline -5`)
5. **State intent:** current task, files to touch, relevant invariants, session mode (interactive / autonomous)

## Completion Criteria

- `devtools::document()` run if roxygen changed
- `R CMD check` clean — warnings SURFACED (invariant 1)
- Schema, exported API, or dependency touched → invariant 2 / 3 verified or ASK posted before commit
- Gaps and follow-ups recorded in `TODO.md`
