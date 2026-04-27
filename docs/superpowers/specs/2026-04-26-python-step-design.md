# Python steps via reticulate — `launch("fit.py")` as first-class

**Status:** design, drafted 2026-04-26. **Roadmap doc, not v1-imminent.** See "Status & sequencing" at the bottom — the immediate forcing function (porting `nn_feedforward.py`) was removed by deciding to port that script to R keras instead. This spec captures the design while the context is fresh; revisit before implementing.
**Scope:** Add a Python script kind to `launch()` so `launch("fit.py")` is treated the same way as `launch("fit.R")`: source the file, hash the bytes, record a `_mr_runs` row, propagate variant labels, honor staleness/skip-if-fresh. The Python script accesses tracked inputs and outputs through a small `modelrunnr` Python module shipped with the package, exposing `mr.grab()` and `mr.stow()` whose semantics mirror their R counterparts.
**Depends on:** existing R-script launch path (`R/launch.R`, `R/launch_one.R`), recording state (`R/recording.R`, `R/helper_tracking.R`), versioned-frame storage (`R/versions.R`, `R/shape_append.R`), reticulate as a new `Suggests:` dependency.

## Non-goals / deferred

- **Inline Python.** `launch(mr_python({ ... }))` is not in v1. Inline R already lives in tension with code-identity (`<inline:hash>` synthetic step ids); replicating that for Python doubles the surface for marginal benefit. Files only for v1.
- **Function-call surface (`launch(mr_python("fit.py", inputs = ...))`).** The "(ii) Python defines a callable, R drives" pattern is a viable second-layer sugar but not in v1. The mirror-of-R surface is the primitive; if (ii) lands later, it is a wrapper that generates a tiny `.py` shim around (i).
- **Non-pandas types across the bridge.** `mr.grab()` returns pandas DataFrames; `mr.stow()` accepts pandas DataFrames. numpy arrays, dicts, scalars, fitted sklearn/torch models all raise. Extending the type contract (numpy in v2, opaque binary blobs for serialized Python objects in v3+) is a follow-up; the rationale for parking is in "Open questions" below.
- **Helper tracking for Python.** R steps track helper functions via `helper_tracking.R`; Python steps do not in v1. Editing an imported `.py` file does not change the entry script's `code_hash`. Document this gap; revisit when someone is bitten.
- **Multiple Python interpreters per session.** One reticulate-bound Python is alive for the R session; v1 does not let users switch interpreter mid-session.
- **Python-side connection to DuckDB.** `mr.grab()` / `mr.stow()` are the *only* Python-side I/O surface. No `mr.con()` exposing a DuckDB handle. The point of going in-process via reticulate is to **eliminate** the second writer; exposing a Python-side connection re-introduces it. Documented as an explicit non-goal so a future contributor doesn't quietly re-open this door.
- **Parallel/subprocess Python execution.** Reticulate is in-process by design. Multi-process Python for parallel folds, etc., is out of scope.
- **CRAN-blocking concerns.** This is a `Suggests:`-level integration; CRAN posture (`skip_on_cran()` for tests, conditional examples) is a packaging detail, not a design question.

## Motivation

modelrunnR's north star is "treat Python very similarly to R" inside the same orchestration harness. Today the package has none of that — a project mixing R and Python steps has to hand-roll the seam. The sibling package `panelmodeler` does this with `system2()` plus DuckDB staging tables (`R/python_model.R` in panelmodeler), which has two lived-with problems:

1. **DuckDB writer-lock conflicts.** `panelmodeler` has to disconnect from the DuckDB store before launching the Python subprocess so the subprocess can open it as a writer. Real-world consequence in the Practicum AI branch: the chunk that runs `models/nn_feedforward.py` had to be marked `eval = FALSE` in vignette/report to avoid a `Could not set lock` failure when both R and Python wanted writer access to `modelrunnR.duckdb` concurrently. Disconnect/reconnect dances are also tedious to get right and break the "implicit connection" UX modelrunnR has otherwise committed to.
2. **DBI staging overhead.** To hand a `train` / `test` data.frame to the Python subprocess, the R caller has to `dbWriteTable()` to a known staging name; the Python script reads that table; then writes its predictions back to another known table; R then `dbReadTable()`s. Several round trips of bytes through DuckDB for what is conceptually "call this Python function with this data.frame." The Python script ends up coupled to specific table names rather than being a clean function of inputs.

A reticulate-backed Python step kind subsumes both:

- The Python interpreter is embedded in the R session, so no second writer ever opens the DuckDB file. The lock conflict structurally cannot occur.
- Pandas ↔ data.frame conversion happens through reticulate's in-memory bridge. No DBI staging tables. The Python script asks for `train` by tracked-name, gets a pandas DataFrame back, returns predictions, and the result is written through modelrunnR's normal versioned-frame storage — same path R steps take.

The motivating concrete case is `models/nn_feedforward.py` in the Practicum AI branch, which today reads `_nn_train_yr%d` / `_nn_pred_yr%d` from the modelrunnR DuckDB by env-var-passed table names. Under this design, that script becomes:

```python
# nn_feedforward.py — under the proposed design
import modelrunnr as mr

train = mr.grab("nn_train_2024")
preds = my_feedforward(train)
mr.stow(preds, "nn_pred_2024")
```

— and the R-side caller is just `launch("models/nn_feedforward.py")`. No `dbWriteTable` / `dbReadTable`, no env-var contract, no `eval = FALSE`. **Note (2026-04-26):** the immediate driver for porting `nn_feedforward.py` shifted to "rewrite in R keras," so this specific motivating example is no longer the forcing function. The motivation generalizes: any future Python step in any project benefits from the same removal of friction. See "Status & sequencing" below.

## Target usage

```r
library(modelrunnR)

# Mixed-language pipeline: R prep, Python model, R analysis.
launch("prep.R")                     # writes _mr versioned frame "training"
launch("models/nn_feedforward.py")   # reads "training", writes "predictions"
launch("score.R")                    # reads "predictions"
```

```python
# models/nn_feedforward.py
import modelrunnr as mr               # ships with the R package, no pip install
import torch
import pandas as pd

train = mr.grab("training")            # pandas DataFrame
model = train_feedforward(train)
preds = pd.DataFrame({
    "id":   train["id"],
    "yhat": model.predict(train.drop(columns=["y", "id"])),
})
mr.stow(preds, "predictions")
```

The user's mental model is: **a `.py` file is a step, just like a `.R` file is a step.** `launch()` dispatches on extension. Everything tracked about an R step (run_id, code_hash, inputs, outputs, status, duration, label propagation, staleness, skip-if-fresh) is tracked identically for a Python step.

## Locked decisions

The following were settled in brainstorming and should not be relitigated when this spec is picked up for implementation. If any of them needs to change, that is a SURFACE per the framework, not a quiet edit.

### D1. Bridge mechanism: reticulate (in-process), not subprocess

Python runs embedded in the R session via reticulate. No `system2()`, no subprocess Python, no DuckDB staging-table handoff. The motivation section explains why; the operational consequence is a `Suggests: reticulate` line in DESCRIPTION (invariant 6 → ASK was answered: yes, add it, but only at `Suggests:` level so users without Python on their machine pay nothing).

### D2. User surface: mirror-of-R, not function-call

The `.py` file is a script that calls `mr.grab()` and `mr.stow()` from inside Python. The Python author writes a script, not a function with a calling convention. Symmetric with `launch("fit.R")` where the R script calls `grab()` / `stow()` directly.

The "Python file defines callables, R drives" surface (option (ii) from brainstorming) is **not closed** as a future addition — it composes cleanly on top of (i) — but it is not part of v1 and the package's primitive remains (i).

### D3. Python module ships inside the R package

A small Python module — proposed name `modelrunnr` (lowercased, importable, single underscore-free token) — ships inside the package at `inst/python/modelrunnr/`. Wired in `.onLoad()` via `reticulate::import_from_path()` so users do `import modelrunnr as mr` from inside a tracked Python step without any pip install, virtualenv setup, or `PYTHONPATH` munging on their part.

The module is small (~50–100 lines, single file or tight package) and has exactly two public surfaces: `grab()` and `stow()`. Both call back into the same R-side recording state (`recording.R`) that `grab()` / `stow()` use — so Python-side I/O lands on the same `_mr_runs.inputs` / `_mr_runs.outputs` arrays as R-side I/O, no parallel bookkeeping.

### D4. Type contract across the bridge: pandas only, both directions

`mr.grab(name)` returns a pandas DataFrame. `mr.stow(value, name)` requires a pandas DataFrame. Anything else raises a typed Python exception (`modelrunnr.TypeContractError` or similar) with a clear message pointing the user at the type-contract docs.

R-side, the conversion is reticulate's stock pandas ↔ data.frame conversion; the resulting R data.frame flows through `.mr_stow_table` (versioned-frame path) the same way an R-side `stow(df, name)` does today. Symmetric for `grab` — the R-side versioned-frame read produces a data.frame, reticulate converts to pandas at the boundary.

The decision was tightly scoped: numpy arrays (B from brainstorming) and opaque binary blobs for serialized sklearn/torch model objects (C) are useful but each opens its own design questions (numpy: matrix vs. data.frame on R side; serialized model objects: format pinning, what R sees on grab, staleness when class definitions change). v1 does the pandas case cleanly.

### D5. The Python step gets a normal `_mr_runs` row

A Python step launches through the same `.mr_launch_one()` envelope as an R script step. It writes a `_mr_runs` row with `step = <normalized .py path>`, `code_hash` from the `.py` bytes, `inputs` / `outputs` populated from the recording state populated by Python-side `mr.grab` / `mr.stow` calls, `status`, `duration_ms`, `started_at`, `code_body` (the .py source for from-db reads), label propagation, helpers (empty for v1 — see D6), and the rest. No new schema. No new sentinel. Existing `_mr_runs` shape absorbs the row.

### D6. Code identity = bytes of the entry `.py` file

`code_hash` is the hash of the `.py` file bytes, the same way an R script step hashes the `.R` file. Helper tracking (other `.py` files imported by the entry script) is **not** done in v1 — editing an imported helper module will not bump the entry script's `code_hash`, and a step that depends on the helper will not show as stale. This is a known gap; it is explicit, documented, and a v2 candidate. R's helper tracking is non-trivial (it observes the call graph at runtime); doing the equivalent for Python is its own design problem and is parked.

### D7. `launch()` dispatch: extension-based

`launch("fit.py")` dispatches to the new Python path the same way `launch("fit.sql")` dispatches to the SQL path today: file extension check inside `launch.R`'s arg-resolution block. No new exported user-facing symbol for v1 (`mr_python()` is not introduced). If the function-call surface (D2's deferred (ii)) lands later, *that* is when `mr_python()` becomes useful as a constructor for "Python step with structured inputs"; for v1, the path is a string and the extension picks the kind.

## Open questions (parked, decide before implementation)

These are real design forks that were not resolved in brainstorming. Listed here so future-you doesn't have to re-derive that they exist.

### O1. Reticulate session lifecycle

Reticulate keeps one Python interpreter alive for the R session by default. That means state from a previous Python step (loaded torch model, populated module-level globals, monkey-patched libraries) persists into the next Python step. R steps share state across launches the same way — a fitted R object in `globalenv()` is visible to the next `launch()` — so symmetry argues for "leave it alone, document it." Counter-argument: Python's larger memory footprint (loaded GPU tensors, etc.) makes leaks more painful, and a "fresh interpreter per step" mode might be desirable. **Decision needed:** persistent (default-and-only), persistent-with-opt-out-flag, or fresh-per-step.

### O2. Python interpreter selection

Reticulate has a non-trivial discovery story (`reticulate::use_python()`, `RETICULATE_PYTHON`, virtualenvs, conda). The package needs a posture: "we don't pick — whatever reticulate picks is what runs," "we expose a `modelrunnR.python = "..."` option," or "we recommend `reticulate::use_virtualenv("r-modelrunnr")` and provide a helper to set one up." **Decision needed**, with a probable lean toward "we don't pick, document the reticulate knobs, fail loudly if pandas isn't available in the active interpreter."

### O3. Error surface

When the Python script throws, reticulate raises an R error containing the Python traceback. The `.mr_launch_one` `tryCatch` already handles errors; the open question is what's stored in `code_body` / `_mr_runs.status` and whether the Python traceback needs to be preserved separately. R errors today land as `status = "error"` with the message in the run row. Python errors should follow suit but the traceback is usually more informative than the message — do we widen `_mr_runs` (invariant 4 alarm — no, additive nullable column would be fine), keep it in the run-row message, or write to logs? **Decision needed.**

### O4. What the bundled `modelrunnr` Python module exposes besides `grab` / `stow`

Minimum for v1 is just those two. Plausible additions: `mr.run_id()` (the active run_id, useful for Python-side logging), `mr.label()` (the propagated variant label), `mr.project_root()` (mirrors R-side `.mr_project_root()`). Any of these widens the contract; each is cheap. **Decision needed.** Lean: ship minimum, add on demand.

### O5. Helper tracking for Python (D6's gap)

When does this become pain? Likely when a user has `models/nn_feedforward.py` that `from common import preprocess` — editing `common.py` doesn't trigger staleness on the step. Two-ish approaches: import-graph walk at launch time (static; hash transitively-imported `.py` files under the project root), or runtime instrumentation (Python equivalent of helper_tracking.R; `sys.settrace` or similar). The first is simpler and probably good enough. **Decision deferred until someone is bitten.**

### O6. Type-contract extensions (D4's parked B and C)

When does pandas-only stop being enough? B (numpy arrays) is the next step and is small; C (serialized Python objects as opaque binary blobs) is bigger and opens "what does R see when it grabs a stowed sklearn model?" — most likely answer is "an opaque python ref" or "an error: this artifact is Python-only." Each extension is its own mini-spec.

## Implementation sketch (for a future plan, not exhaustive)

When this gets picked up, the implementation plan will likely look like:

1. **Add `Suggests: reticulate` to DESCRIPTION** (invariant 6 — ASK already resolved in this spec).
2. **Bundle `inst/python/modelrunnr/__init__.py`** with `grab(name)` and `stow(value, name)`. The body of each is a one- or two-line call back into R via reticulate's `r` object: `r.modelrunnR_python_grab(name)` and `r.modelrunnR_python_stow(value, name)`. Type-check pandas DataFrame, raise `TypeContractError` otherwise.
3. **Add R-side internal entry points** `.mr_python_grab(name)` and `.mr_python_stow(value, name)` that the Python module calls into. They thunk to the same recording-state-aware machinery `grab()` / `stow()` use today, so a Python-side stow/grab lands on the active run's input/output arrays exactly the same as an R-side one.
4. **Wire `.onLoad`** to make the bundled module importable: `reticulate::import_from_path("modelrunnr", system.file("python", package = "modelrunnR"))` (gated on reticulate availability — if the user doesn't have reticulate, `launch("fit.py")` errors with a clear "install reticulate to use Python steps").
5. **Extend `launch.R` dispatch** to recognize `.py` extension alongside `.R` and `.sql`. Add `.mr_launch_python(step, ...)` analogous to `.mr_launch_sql`, calling reticulate's `source_python(step)` inside the existing `.mr_launch_one` recording / on-exit envelope. Per D6, the R-specific helper-tracking is *not* invoked for Python steps in v1.
6. **`code_hash` for `.py`**: hash the file bytes, same as R script. (No helper tracking — D6.)
7. **`launch_code(run_id)` for Python runs**: the existing implementation already prefers on-disk file then falls back to stored `code_body`; that works as-is for `.py` files.
8. **Tests**: a small `tests/testthat/test-launch-python.R` gated on `skip_if_not_installed("reticulate")` and `skip_if(!reticulate::py_module_available("pandas"))`. Cases: round-trip a DataFrame; type-contract error on stowing a non-DataFrame; staleness when the `.py` file is edited; label propagation from an upstream R step into a Python step and back into a downstream R step.
9. **Docs**: a vignette section "Mixing R and Python steps" once the implementation is in. Until then, this spec is the doc.

## Status & sequencing

- **Blocked on:** nothing. Could be implemented now; chose not to.
- **Why parked:** the immediate forcing function (porting `models/nn_feedforward.py` to live cleanly inside modelrunnR) was removed by deciding to rewrite that script in R keras instead. Without a real second user, the open questions above (O1–O6) would be answered without enough information.
- **Sequencing relative to other in-flight specs:** depends on stow-unification (`2026-04-26-stow-unification-design.md`) being landed first. Python steps reuse the unified stow path — D4 explicitly assumes the versioned-frame storage that stow-unification ships. Building on a moving target doubles the rework.
- **Trigger to revisit:** any of (a) a user / project actually needs a Python step; (b) the function-call sugar (option (ii)) becomes desired and we want the primitive in place first; (c) the type-contract gets extended (numpy or serialized Python objects) — would force pandas-only assumptions to be made explicit anyway.
- **Estimated effort once unparked:** ~3–5 days for D1–D7 plus tests; O1–O6 add proportionally if any are answered "yes, do that too."
