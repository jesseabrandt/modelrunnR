---
source: R/staleness.R
generated: '2026-04-25'
reviewed: ''
reviewed_commit: ''
verdict: unreviewed
feedback: ''
---

# R/staleness.R

## `.mr_is_stale(step, variant_label = NA_character_, rebind = list()`
_line 33_

Check whether a step is stale relative to its most recent run

Compares the current state of the script file, its recorded
helpers, its recorded inputs, and its recorded external inputs
against the most recent `_mr_runs` row for this step. Returns a
list with `stale` (logical) and `reasons` (character vector).

@param step Normalized path to the step's script file.
@param variant_label When non-NA, restrict the "most recent run" lookup to
  runs with this exact label. When NA (the default), the lookup considers
  any run for this step, regardless of label.
@param rebind Optional `name -> content_hash` map for names the
  about-to-fire launch has explicitly rebound. When a recorded
  input name appears in this map, the input-arm compares its
  recorded hash against the rebound hash rather than against the
  current latest version — so a repeated launch under the same
  pin stays fresh even if the pinned name has since moved on.

@return A list with fields `stale` and `reasons`.
@keywords internal

## `.mr_check_code_hash(step, prior)`
_line 79_

## `.mr_check_code_hash_inline(step, prior)`
_line 121_

## `.mr_check_inputs(con, inputs_json, rebind = list()`
_line 163_

## `.mr_check_external_inputs(external_json)`
_line 210_
