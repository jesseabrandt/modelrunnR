---
source: R/mr_binds.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/mr_binds.R

## `mr_binds(..., mode = c("zip", "cross")`
_line 36_

Build a batch of `launch(rebind = ...)` envelopes

Pure list constructor for a sweep of rebinds. Each named `...`
argument is the vector of values for that rebind slot. Pass the
returned object to `launch(rebind = ...)` and the launch fans out
into one run per envelope.

Two expansion modes:

* `mode = "zip"` (default) -- element-wise pairing. All `...`
  arguments must share one length N (length-1 recycles to N).
* `mode = "cross"` -- Cartesian product. N = product of lengths.

Values flow through unchanged: pass `mr_variant("clean")` to
resolve to a labeled variant's latest hash, `mr_hash("...")` to
address a specific version, or a bare R value to stow inline. If
you want to sweep over variant labels, use `mr_variants(...)` to
avoid passing bare strings as literal values.

Optional `.labels` is a character vector (length N after expansion)
of explicit labels for the runs. When `NULL` (default), labels are
left unset and the existing label-auto-propagation path fills them
from upstream variants.

@param ... Named sweep arguments. Each value is a vector / list of
  per-envelope values for that rebind slot.
@param mode `"zip"` (element-wise) or `"cross"` (Cartesian product).
@param .labels Optional character vector of explicit labels (one per
  envelope after expansion).
@return An `mr_binds` object: a classed list of envelope lists, each
  suitable as the `rebind =` value of a single `launch()`.
@seealso [mr_variants()] for sweeping over variant labels;
  [mr_envelopes()] for hand-built envelopes when `mr_binds()`'s
  sweep API isn't expressive enough.
@export

## `.mr_binds_zip(slots, lens)`
_line 78_

## `.mr_binds_cross(slots, lens)`
_line 102_

## `mr_variants(...)`
_line 140_

Build a vector of variant references

Convenience for `mr_binds(<name> = mr_variants("clean", "raw"))` so
bare strings aren't accidentally passed as literal rebind values.
Equivalent to `list(mr_variant("clean"), mr_variant("raw"))`.

Sibling helpers (`mr_hashes`, `mr_runs`, `mr_as_ofs`) are not
provided in v0.1; ship on demand.

@param ... Bare strings naming variants.
@return A list of `mr_variant` references.
@seealso [mr_binds()] for the sweep constructor that consumes this;
  [mr_variant()] for the single-reference form.
@export

## `mr_envelopes(...)`
_line 172_

Build batch envelopes by hand

Primitive constructor under `mr_binds()`. Use this when you want
per-envelope `.label`, mixed reference kinds across envelopes, or
any other shape that the simpler `mr_binds()` sweep API doesn't
express.

Each `...` argument is a named list. A `.label` field, if present,
is the explicit run label for that envelope; all other names are
rebind slots (their values flow through resolution unchanged, exactly
like values inside `launch(rebind = list(...))`).

@param ... One or more named lists, each describing a single
  envelope.
@return An `mr_binds` object.
@seealso [mr_binds()] is the sugared form; reach for `mr_envelopes()`
  only when you need per-envelope `.label` or mixed reference kinds
  across envelopes.
@export
