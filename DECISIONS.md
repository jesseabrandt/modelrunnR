# Decision log

Design- and model-affecting choices for this project, from **2026-06-09** forward.
Reversible choices are EXECUTE-and-logged by agents; substantive ones are routed
through `dq` → `/decisions` and recorded here on resolution. This file is the
permanent, inspectable record of *why this project is shaped the way it is*.

**Provenance note:** anything in this repo predating this log is **unattributed and
not settled** — it may be Jesse's choice or an agent's, reviewed or not. `north_star.md`
(if present) is Jesse's, as of its date. Agents: do not cite pre-log code or structure
as "already decided" — promote load-bearing pre-log choices through `dq` (substantive)
or `dlog` (reversible) before building on them.
See `~/workspace/docs/decision-log.md` for the convention.

---

## 2026-06-09 — adopt the decision-log convention
- **Choice:** DECISIONS.md per docs/decision-log.md (workspace repo)
- **Why:** design choices from today forward are logged or queued, never silent; pre-log contents are unattributed and not settled until promoted
- **Reversible:** no · **Decided by:** jesse

## 2026-06-11 — Non-ASCII WARNING fix: only the string literal, keep comment em-dashes
- **Choice:** Replaced the single em-dash inside the sprintf() error string in R/dispatch_code.R with ASCII; left the U+2014 em-dashes in comments untouched.
- **Why:** R CMD check parses-then-deparses R code, so comment non-ASCII is dropped and never flagged; only string-literal non-ASCII survives to trigger the WARNING. The probe/task attributed it to comments, but empirically the sole code-level culprit was the error string. Fixing only it clears the WARNING while honoring the intentional Unicode comment/roxygen house style.
- **Reversible:** yes · **Decided by:** agent

## 2026-06-11 — Project-marker fallback warns once per working directory
- **Choice:** db_path() now records each marker-less working dir in .mr_state and warns only the first time it falls back for that dir, instead of on every stow()/launch()/grab().
- **Why:** Probe saw a wall of identical warnings on first run in a scratch dir because db_path() is called on every op. Once-per-dir keeps the advisory informative without burying a session.
- **Reversible:** yes · **Decided by:** agent

## 2026-06-11 — README: point Linux users at a binary package repo (P3M)
- **Choice:** Kept pak with the corrected jessebrandtdata slug and added a Linux note to install via Posit Public Package Manager so deps come as binaries, not a full source compile.
- **Why:** Probe OOM'd compiling the whole dep tree from source in a constrained box; default CRAN is source-only on Linux. Binary repo avoids the compile without hardcoding a fragile one-size URL.
- **Reversible:** yes · **Decided by:** agent
