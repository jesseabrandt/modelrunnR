# Framework — modelrunnR

**North star:** [north_star.md](north_star.md)

## Invariants

1. **Don't break `../practicum_repos/final_practicum`.** If a change would break it, ASK before proceeding.
2. **`R CMD check` must pass before claiming a task done.** "Tests pass" is not enough on its own.
3. **Spec primacy.** When a spec exists for the work (under `docs/superpowers/specs/`), the implementation matches it. Deviations are SURFACED, not silently chosen.
4. **Schema migrations are append-only.** Add nullable columns; never drop or rename existing columns in `_mr_runs` / `_mr_versions` / other backend tables without ASK. Users have DuckDB stores in the wild and renames are unrecoverable.
5. **Exported API is a contract.** Don't change the signature of an `@export`'d function, rename an exported symbol, or remove `@export` without ASK.
6. **No new `Imports:` without ASK.** Per CLAUDE.md, the package stays lean.

## Decision Tree

ASK/SURFACE post immediately and only block dependent work — see north-star-execute "Surface-and-continue". Collapse repeat ASKs to the principle level (one design question, not N instance questions).

```
├─ Explicit in active spec/plan?               → EXECUTE
├─ Standing invariant above?                   → EXECUTE
├─ Closed decision (spec, todo, memory)?       → EXECUTE
├─ Bug in call graph, blocking task?           → EXECUTE (note in commit)
├─ Bug outside call graph?                     → SURFACE (don't touch)
├─ Touches _mr_runs / _mr_versions schema
│  in a non-additive way?                      → ASK (invariant 4)
├─ Changes an @export'd signature
│  or removes an @export?                      → ASK (invariant 5)
├─ Adds a new Imports: dependency?             → ASK (invariant 6)
├─ Could break ../practicum_repos/
│  final_practicum?                            → ASK (invariant 1)
├─ Design decision with >1 valid answer?       → ASK
├─ Touches shared state (remote, CI,
│  parallel work)?                             → ASK
├─ Would violate an invariant?                 → ASK
└─ Opportunistic cleanup, unrelated?           → QUEUE to TODO.md (don't touch)
```

**Test for "closed decision":** Has the user already said what the answer is, anywhere — spec, todo, memory, conversation? If yes, execute. If no, ask.

## Session Start Ritual

1. Read `north_star.md`
2. Read this framework
3. Read the active spec(s) under `docs/superpowers/specs/` (most recent first)
4. Skim `TODO.md`
5. `git status` and `git log --oneline -5`
6. **State intent:** current task, files to touch, invariants in play, session mode (interactive / autonomous)

## Completion Criteria (per task)

- All spec/plan steps committed
- `devtools::document()` run if roxygen changed
- `R CMD check` clean — warnings are SURFACED, not swallowed (invariant 2)
- If schema, exported API, or dependency touched → invariant 4 / 5 / 6 verified or ASK posted before commit
- If change is potentially breaking for `../practicum_repos/final_practicum` → ASK posted (invariant 1)
- Gaps and follow-ups recorded in `TODO.md` or `docs/followups.md`

## Tips (not invariants — judgment, not gates)

- Don't add features, refactor, or introduce abstractions that weren't asked for. (CLAUDE.md.)
- When adding harness/runner code, check how `panelmodeler` solves the same problem first; generalize rather than copy. (CLAUDE.md.)
- Vignettes are user-facing onboarding — keep them knittable when touching code they reference.
- **Survey existing conventions before proposing new ones.** Before introducing a new internal tag, sentinel column value, status string, or state class, grep the package for whether one already exists for the same conceptual slot. If versioned-shape handles "outside launch" with pattern Y, append-shape uses pattern Y too — don't introduce a parallel name for the same underlying concept without SURFACING why the existing one doesn't fit.
