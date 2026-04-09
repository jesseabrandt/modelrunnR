# modelrunnR — Swappability Design Notes

**Status**: Discussion document. Captures a clarification of how variant
identity, substitution, and discoverability fit together. Does **not** replace
`design.md`; extends it and in a few places revises it. The intent is that
these notes are folded into `design.md` in a dedicated commit after review.

**Last updated**: 2026-04-09

**Relationship to `design.md`**: this doc formalizes what `design.md`
currently calls *Parameter passing and sweeps* (tentative) into a first-class
design principle. Where the two documents conflict, treat this doc as the
newer intent. Cross-references to the exact sections being extended are
listed at the bottom.

---

## 1. Motivation: swappability is a principle, not a sweep mechanic

The existing `design.md` describes `pin`/`data` as a mechanism for parameter
sweeps. Conversation with the first user surfaced a deeper framing:
**every `grab()` is a default binding, and `launch()` can rebind any name.**
Sweeps, parameter variation, feature substitution, and "run this with
yesterday's data" are all special cases of one idea — *substitution at grab
time.*

Two concerns drive this reframing:

1. **A script run with different bindings is not "the same step with
   different inputs."** It is, from the user's point of view, a different
   computation worth tracking separately. The current design treats two
   runs of `fit_xgb.R` with different `params_xgb` as two runs of one step,
   which loses the user's distinction.

2. **The value of a grab grows with the other grabs in the same script.**
   A script with zero grabs is a monolith — it produces one thing. A script
   with N grabs has N axes along which behavior can be swapped. Adding a
   grab is not just "more tracking"; it's creating a new experimental axis.
   The package should teach this progression and reward it.

## 2. Core principle: grabs are articulation points

Every `grab()` call is a seam where behavior can be swapped at launch time.
The more articulated a script is — the more of its inputs are grabbed rather
than hardcoded — the more variation the framework can express and track.
This is the property `modelrunnR` should teach users to internalize.

Concretely: a script that reads a CSV path literal, a learning-rate literal,
and a formula literal has zero articulation points. The same script rewritten
to grab `features`, `params_xgb`, and `target_formula` has three. With three
articulated inputs, the user can vary any of them independently, track the
history of each, and compose variants across them — without editing the
script.

The package's job is to make articulation **cheap** (two-line conversion
from literal → grab) and **valuable** (each new grab unlocks tracking,
swapping, and discoverability).

## 3. Taxonomy: script / variant / run

Three levels of identity. Two existed implicitly in `design.md`; the middle
one is new.

### Script

A file on disk. Identity: absolute path. Mutable — code changes as the user
edits. `launch()` takes a script path as its primary argument. Nothing here
changes what a script is; it remains the thing users edit, commit, and
revert.

### Variant *(new)*

A specific *instantiation* of a script: script code plus the hashes its
grabs resolved to. Identity has two layers:

- **Internal:** `hash(code_hash, sorted(input_name → input_hash))` — an
  audit-grade fingerprint of the exact computation that ran.
- **User-facing:** an optional **label** (free-text string) that the user
  assigns via `launch(..., label = "eta_0.01")`. The label is the durable
  handle the user grabs by, prunes by, and reasons about. The internal
  fingerprint can change across code edits while the label stays stable.

A variant is a unit the user has **expressed intent** to distinguish.
Unlabeled runs of a script are not variants.

### Run

A single execution of a variant (or of a plain, unlabeled script). Identity:
`run_id` + timestamp. This is today's `_mr_runs` row. Multiple runs of one
variant (same code, same bindings, re-executed on different days) share a
label but get distinct `run_id`s.

### The word "step"

`design.md` currently defines `step = script path`. Under this doc, "step"
is a looser word used in prose to mean *"a unit of computation the user
runs"* — sometimes a script, sometimes a variant, depending on context. The
`_mr_runs.step` column (which stores a script path) stays as-is; no rename.
This preserves the existing schema while giving "variant" room to be the
load-bearing identity.

## 4. Variants are opt-in

**A variant exists when a run has a non-null label.** Labels arrive one
of two ways:

1. **Explicit** — the user passes `label = "…"` to `launch()`. Plain-run
   labeling is allowed (a "bookmark" use: *"this was the run I showed in
   the meeting"*); it gets the same treatment as a sweep label.
2. **Auto-propagated** — when no explicit label is given, and all the
   resolved-hash producers for the script's grabs agree on a single
   label, that label is inherited. See §5.

Runs without labels are plain runs, tracked exactly as today. **Passing
`data=` or `pin=` without a `label=` does not by itself mint a variant.**
Those arguments are mechanisms for controlling *which computation runs*,
not for declaring a tracked experimental thread. A plain run with
`data=` is still a run with a recorded input hash for the injected name
— it just doesn't become a durable handle the user can `grab()` back or
protect from pruning.

Why this line: the label is the only user-facing identifier for a
variant. A variant without a label would be an orphan — no way to
reference it, no way to prune-protect it, no way to surface it in
`variants(script)`. The label is what makes a variant a *thing*; without
one, a "variant" is just a run with unusual inputs.

**What this prevents.** Hash-distinct runs do not mint variants on their
own; only user intent (a label, explicit or inherited) does. Casual
iteration — edit, run, edit, run, fix a typo — produces plain runs
exactly as today. Comment edits, upstream drift, iterative debugging:
none of them mint variants. Hashes still change, version rows still
accumulate via the existing hybrid versioning; no variant machinery
engages. The "just because a hash is different doesn't mean both
versions matter" concern is addressed directly.

**What's preserved.** If the user wants to label every sweep iteration,
they pass `label=` in the loop body — one argument per launch. If they
want the cascade to carry the label downstream automatically,
auto-propagation does that.

## 5. Auto-propagation rule

When `launch(script)` runs without an explicit `label`, the framework
inspects each grab the script makes, checks whether any resolved hash came
from a run in a labeled variant, and aggregates:

1. **All labeled upstreams agree on one label** → **inherit.** The
   downstream run is recorded under that label. If this is the first run of
   the variant for this script, the variant is created; otherwise, the run
   is appended. A launch-time message announces the inheritance:

   ```
   modelrunnR: predict.R [success] in 2,312 ms (3 grabs, 1 stow)
     variant: eta_0.01 (inherited from model_xgb)
   ```

2. **Upstreams disagree** (e.g., `model_xgb` from `eta_0.01`, `features`
   from `fast_features`) → **no inheritance.** The run is plain. A warning
   is emitted:

   ```
   ambiguous upstream variants: model_xgb → eta_0.01, features → fast_features.
   Running without a label; pass label= to disambiguate.
   ```

3. **No labeled upstreams** → plain run, no variant. Identical to today.

4. **Explicit `label=` at launch** → overrides everything; user's label
   wins silently.

5. **`data=` without `label=`, upstreams agree on `eta_0.01`** →
   **inherit `eta_0.01`.** Inline data is how the user delivered input;
   they did not claim a new thread, so the upstream label carries. The
   launch-time message still surfaces that inheritance happened.

**Why propagation is bounded.** A downstream run can only inherit labels
that already exist upstream. The number of propagated variants is capped
by the number of labeled variants the user deliberately created.
Auto-propagation extends labels along paths the user has not contradicted;
it does not invent new ones. Variant explosion is therefore not a risk.

**How this addresses the code-edit concern.** Labels span code edits. A
tweak to a comment in `fit_xgb.R` changes `code_hash` but not the label.
Tomorrow's `launch("fit_xgb.R", label = "eta_0.01", data = ...)` is a new
run of the same labeled variant, with a different `code_hash` recorded for
audit. Users operate on the label; the hash is the audit trail.

## 6. Management surface (v0.1)

Two principles for keeping this small:

- **Labels live as data on runs**, not as a separate table. A dedicated
  `_mr_variants` metadata table can wait until labels need lifecycle
  attributes beyond what fits on a run row.
- **Deletion of labeled variants is not in v0.1.** Labels are a "keep
  these around" signal; bulk cleanup can wait for real need.

### 6.1 Schema change

A single nullable column added to `_mr_runs`:

| column | type | meaning |
|---|---|---|
| `variant_label` | TEXT (nullable) | user-provided or auto-propagated label; NULL for plain runs |

No change to `_mr_versions`. The relationship *variant → version* is
derived via `_mr_runs.outputs`.

### 6.2 New arguments on existing functions

- **`launch(..., label = NULL)`** — new argument. Behavior specified in
  §4 and §5. Labels are free-text strings; v0.1 performs no validation
  beyond trimming whitespace and rejecting the empty string.

- **`grab(name, variant = NULL)`** — new argument. Resolves to the latest
  `content_hash` for `name` produced by a run whose `variant_label`
  matches, ordered by `_mr_runs.started_at DESC`. Errors cleanly if no
  such variant has produced this name:

  ```
  no variant named 'eta_0.01' has produced 'predictions'.
  ```

  Orthogonal to the existing `version`, `from_run`, and `as_of`
  arguments; specifying more than one selector is an error (existing
  behavior).

- **`prune_versions(..., force = FALSE)`** — protection rule added. Any
  version whose producing run has a non-null `variant_label` is
  **unconditionally protected** from pruning. `force = TRUE` overrides
  (same as the existing run-protection override). The normal `keep = N`
  and `older_than` policies **do not** apply to labeled-variant versions.
  Labels are the user's explicit "keep this" signal; subtle override
  rules are avoided so the promise is easy to read.

### 6.3 New functions

- **`variants(script = NULL, name = NULL)`** — inspection. Returns a
  data frame. Called with neither argument, lists every distinct label in
  the system. With `script =`, lists variants of that script. With
  `name =`, lists variants that have produced outputs under that logical
  name. Columns: `script`, `label`, `first_seen`, `last_seen`, `n_runs`,
  `latest_run_id`.

- **`variants_unexplored(script)`** — discoverability. Returns, for each
  grab the script has historically made, which labeled upstreams exist
  and which have been exercised by this script:

  | column | meaning |
  |---|---|
  | `logical_name` | name the script grabs |
  | `upstream_label` | a labeled variant that has produced this name |
  | `upstream_hash` | the content_hash that variant produced |
  | `last_seen` | when the upstream run happened |
  | `used_by_this_script` | `TRUE` if any run of this script consumed this upstream hash |

  A user scanning this table sees at a glance which experimental
  combinations they haven't run downstream yet.

- **`prune_variants(script = NULL, label = NULL, dry_run = FALSE)`** —
  deletion. Removes a labeled variant by deleting matching rows from
  `_mr_runs`. Mechanics:

  - Both `script` and `label` must be supplied; calling with only one
    is an error. (No global "delete all variants" shortcut — that would
    be too easy to invoke by accident.)
  - Counts affected runs and prints a summary before executing. With
    `dry_run = TRUE`, prints the summary and returns without deleting.
  - The deletion itself is `DELETE FROM _mr_runs WHERE step = ? AND
    variant_label = ?`. No cascade logic.
  - Returns the summary invisibly.

  **Cascade is handled by existing machinery.** Once the variant's runs
  are gone, the versions they produced are subject to the normal
  *"referenced by recent runs"* protection rule:

  - If a downstream plain run consumed one of the deleted variant's
    outputs, that plain run's `inputs` JSON still references the
    version hash, so the version stays protected.
  - If nothing downstream references it, the version becomes a
    candidate for the next `prune_versions()` call.

  **Downstream labeled variants are left alone.** If `predict.R:eta_0.01`
  inherited from `fit_xgb.R:eta_0.01` and the fit variant is deleted,
  the predict variant still exists with its recorded input hashes — the
  link is just historical. A user who wants to tear down a whole
  labeled pipeline calls `prune_variants()` at each level explicitly.
  Automatic labeled-cascade deletion is a policy choice deferred past
  v0.1.

### 6.4 Launch-time summary extensions

The existing timing/staleness summary gains two additions:

- **Grab/stow counts** — visible on every launch, always. A gentle
  always-present articulation nudge:

  ```
  modelrunnR: predict.R [success] in 2,312 ms (3 grabs, 1 stow)
  ```

- **Variant line** — only when relevant:

  ```
    variant: eta_0.01 (inherited from model_xgb)
    2 other variants of model_xgb exist but weren't used here: eta_0.05, eta_0.10
    run `variants_unexplored("predict.R")` for details
  ```

### 6.5 Explicitly deferred to v0.2+

- **`rename_variant(script, old_label, new_label)`** — to fix typos.
- **`launch_unexplored(script)`** — actually run the missing combinations
  from `variants_unexplored()`.
- **Automatic labeled-cascade deletion** — a `prune_variants(..., cascade = TRUE)`
  mode that walks downstream labeled variants and deletes them too.
  Policy-heavy; deferred until real usage shows what the right default
  is.
- **A dedicated `_mr_variants` metadata table** — only if labels need
  attributes that don't fit on runs.

## 7. Grabs-as-articulation-points: docs and affordances

### 7.1 Docs are the primary vehicle

The README and introductory vignette should walk a user through a
deliberate progression:

1. **Hardcoded script.** CSV path, hyperparameters, and formula written
   inline. One-time use.
2. **First grab.** Replace the CSV read with
   `grab("features", source = "path.csv")`. Features is now a versioned
   named entity.
3. **Second grab.** Lift the hyperparameters into a `params_xgb` grab.
   The script can now be run with different params via
   `launch(..., data = list(params_xgb = cfg))`.
4. **Feature substitution.** Rewrite the model call to use `y ~ .` and
   swap which features table is grabbed. Different feature sets become a
   single-line sweep axis.
5. **Downstream consumption.** A second script grabs outputs from the
   first. Variants cascade automatically when labels are in play.

Each step should feel like a small, obvious refinement — because the
framework makes the next capability fall out naturally from adding one
more grab.

### 7.2 The `y ~ .` sharp edge

The features-as-parameter pattern has one hazard worth noting in the
vignette: `y ~ .` means *"all non-`y` columns in whatever data frame you
pass."* Swapping a 20-column features table for a 25-column features
table silently picks up five new predictors. For tree learners this is
usually fine; for linear models with regularization it can be
surprising. This is an R formula-semantics issue, not a `modelrunnR`
issue — the vignette should name it in one sentence so readers don't
take the pattern too literally and get bitten.

### 7.3 Launch-time counts, no linter

The grab/stow counts in the launch summary are the only in-API nudge.
They make articulation visible on every run — `(0 grabs, 1 stow)`
appears every time a hardcoded script runs, which is itself a gentle
hint without imposing a value judgment.

**Rejected:** a `suggest_grabs(script)` linter. It would require
modeling which R expressions are "grab-able" (literal paths? literal
numerics? formulas with named columns?) and inevitably imposes opinions
the user may not share. Deferred indefinitely.

## 8. Future directions

Items parked for v0.2 or later. This section exists so that the v0.1
implementation does not accidentally close the door on them.

### 8.1 Virtual stow / inline recomputation

A per-name knob that swaps storage cost for compute cost: an intermediate
marked "virtual" is not materialized to disk; subsequent `grab()` calls
recursively re-launch the producing script to recompute the value on
demand. Useful when the intermediate is cheap to compute (~seconds) but
expensive to store (~hundreds of MB).

**Architectural fit.** The grab-side read path already goes through hash
indirection; virtual stow is one extra check at the top: look up
`_mr_versions.materialization`; if `'virtual'`, find the producing script
via `_mr_runs.outputs` and recursively `launch()` it. Cycle detection
via a package-state "currently recomputing" set prevents infinite loops.

**Variant interaction.** Virtual stow + variants composes cleanly.
`grab("features", variant = "eta_0.01")` recomputes the `eta_0.01`
upstream. Compute cost scales with *variants actually grabbed* rather
than variants ever run — exploration without storage cost.

**Staleness interaction.** A virtual intermediate is never "stale from
its upstream" because it is recomputed at read time. Virtual stow is
only meaningful in contrast to *stored* intermediates.

**What v0.1 must do to preserve this option.**

- The grab-side read path in `R/grab.R` should not bake in
  "rows are always stored" assumptions. A future `materialization`
  column check should be a drop-in at the top of the resolver.
- Adding a `materialization TEXT` column to `_mr_versions` must remain a
  purely additive schema change.
- The knob's user-facing shape (package-wide option, per-stow flag at
  write time, or per-name marker set retroactively) is explicitly
  unresolved.

### 8.2 Bulk variant operations

`rename_variant()`, `launch_unexplored()`, and a cascade mode for
`prune_variants()`. See §6.5.

### 8.3 Script move detection

If a user moves a script file — from `fit_xgb.R` to `models/fit_xgb.R`,
say — a naive `launch()` on the new path creates fresh runs under a
new `step` value, orphaning the prior history from the script's
perspective. The runs are still there, still queryable, but the
timeline is visually split.

**The detection signal is nearly free.** `_mr_runs.code_hash` already
records the hash of the script contents plus helpers. If a new launch
produces a `code_hash` that matches prior runs with a *different*
`step` path, the script was (probably) moved. At launch time this can
surface as an advisory:

```
modelrunnR: this script may have been moved.
  prior runs with matching code_hash found under:
    fit_xgb.R (17 runs, last seen 2026-04-05)
  to re-parent them to the new location, run:
    rename_step("fit_xgb.R", "models/fit_xgb.R")
```

**`rename_step(old_path, new_path)`** is a small function: one UPDATE
over `_mr_runs` rewriting the `step` column from old to new.
Straightforward, maybe 20 lines.

**Automatic silent re-parenting is rejected.** Two unrelated scripts
can share a `code_hash` in principle — rare, but especially for
near-empty scripts or boilerplate — and silent re-parenting on a false
positive is a bad failure mode. Manual `rename_step()` is the safe
surface; detection is advisory only.

**Fit for v0.1:** no. This is a cleanup affordance, not a core
semantic. Parked here so the v0.1 implementation doesn't accidentally
close the door — which it won't, since both the detection and the
rename are purely additive on top of what's already in `_mr_runs`.

### 8.4 Label validators

v0.1 labels are free-text. Typo drift (`"eta_0.01"` vs `"eta_.01"`) is a
real risk but one the user can self-police in a loop body. A future
slice may add a label registry or a `valid_labels = c(...)` constraint
argument on `launch()`.

## 9. Cross-references to `design.md`

Places where this doc extends, clarifies, or supersedes current
`design.md` text. The eventual merge should touch these sections
explicitly.

- **§ *The script is the step; the I/O calls are the declarations*** —
  still true, but "step" in that section is the looser prose use; the
  identity-bearing concept is now "variant."
- **§ *Parameter passing and sweeps*** — reframed entirely. Sweeps are
  no longer a tentative mechanism; they are one application of the
  variants/labels system. The `pin`/`data` arguments on `launch()`
  remain; a new `label` argument joins them.
- **§ *Staleness model*** — staleness is per-variant when a variant is
  in play, per-script otherwise.
- **§ *Open questions* — "`data`/`pin` + script `stow()` collisions"** —
  resolved. Bindings and stows are separate axes: a binding is a
  grab-side input, a stow is an output-side write. No collision.
- **§ *Open questions* — "Scope of 'recent run records' for GC
  protection"** — partially resolved. Labeled-variant runs are
  unconditionally protected; the "recent runs" question remains open
  for unlabeled runs.
- **§ *MVP architecture* / *User-facing API (v0.1)*** — gains three new
  functions (`variants`, `variants_unexplored`, `prune_variants`) and
  new arguments on `launch` and `grab`.

A dedicated merge commit should fold these changes into `design.md`
once this doc is approved.
