## Internal: shared first-argument dispatcher for launch() and queue().
##
## Both verbs accept (a subset of) the same first-argument shapes — a
## braced inline block, an .R file path, an .sql file path, mr_sql(),
## mr_label(), mr_run(), mr_hash(). Each verb's dispatch ladder then
## branches on shape, captures step + code_body, and rejects shapes
## outside its accept set. This helper consolidates the ladder so the
## accept set becomes a parameter and both verbs share one
## implementation.
##
## Inputs:
##   code         the value bound to the caller's `code` parameter.
##   script_expr  the unevaluated expression captured by the caller via
##                substitute(code), used to detect a literal `{ ... }`.
##   accept_refs  character vector, subset of c("label", "run"). Names
##                of mr_ref kinds the caller accepts as a first arg.
##                mr_hash() is never accepted as a first arg.
##   accept_sql   TRUE if the caller accepts .sql paths and mr_sql().
##   caller       "launch" or "queue", used only to compose error
##                messages.
##
## Returns a list with:
##   kind        one of "inline", "file", "sql_inline", "sql_file",
##               "ref_label", "ref_run".
##   inline_mode TRUE iff kind == "inline".
##   step        "<inline:hash>" or normalized path or
##               resolver-provided step.
##   code_body   the body text (verbatim, from disk, or from
##               snapshot via the resolver fallback).
##   code_hash   set for non-ref kinds; NULL for ref kinds (the
##               caller computes from the resolver's body using the
##               appropriate inline-vs-file rule, see spec).
##   ref         NULL for non-ref kinds; for ref kinds, the resolver's
##               full return list (step, code_body, expr,
##               variant_label [run-only], status [run-only]).
.mr_dispatch_code_arg <- function(code, script_expr,
                                  accept_refs = character(0),
                                  accept_sql  = FALSE,
                                  caller      = "launch") {
  inline_mode <- is.call(script_expr) &&
    identical(script_expr[[1]], as.name("{"))

  if (inline_mode) {
    code_body <- paste(deparse(script_expr, width.cutoff = 500L),
                       collapse = "\n")
    expr_hash <- .mr_hash_bytes(charToRaw(code_body))
    step      <- sprintf("<inline:%s>", substr(expr_hash, 1L, 12L))
    code_hash <- .mr_code_hash_inline(code_body, list())
    return(list(
      kind        = "inline",
      inline_mode = TRUE,
      step        = step,
      code_body   = code_body,
      code_hash   = code_hash,
      ref         = NULL
    ))
  }

  # mr_sql() check must precede the general .mr_is_ref() branch:
  # mr_sql() returns class c("mr_ref_sql", "mr_ref"), so the general
  # ref branch would otherwise match it first with the wrong message.
  if (inherits(code, "mr_ref_sql")) {
    if (!accept_sql) {
      stop(sprintf(
        "%s(): SQL staging via mr_sql() is out of scope (v1).", caller
      ), call. = FALSE)
    }
    return(list(
      kind        = "sql_inline",
      inline_mode = FALSE,
      step        = NA_character_,    # SQL path computes its own step
      code_body   = code$body,
      code_hash   = NULL,
      ref         = NULL
    ))
  }

  if (.mr_is_ref(code)) {
    if (!(code$kind %in% accept_refs)) {
      # Compose the rejection message in launch's existing style if the
      # caller is launch (mentions which refs ARE accepted), and in
      # queue's existing style otherwise (says the kind is not accepted
      # as a first-argument reference).
      if (identical(caller, "launch")) {
        stop(sprintf(
          "%s(): only %s are accepted as first argument references; got mr_%s().",
          caller,
          paste(sprintf("mr_%s()", accept_refs), collapse = " and "),
          code$kind
        ), call. = FALSE)
      } else {
        stop(sprintf(
          "%s(): mr_%s() is not accepted as a first-argument reference.",
          caller, code$kind
        ), call. = FALSE)
      }
    }

    if (identical(code$kind, "label")) {
      resolved <- .mr_resolve_relaunch(code$value)
      return(list(
        kind        = "ref_label",
        inline_mode = FALSE,
        step        = resolved$step,
        code_body   = resolved$code_body,
        code_hash   = NULL,
        ref         = resolved
      ))
    }
    if (identical(code$kind, "run")) {
      resolved <- .mr_resolve_relaunch_run_id(code$value)
      return(list(
        kind        = "ref_run",
        inline_mode = FALSE,
        step        = resolved$step,
        code_body   = resolved$code_body,
        code_hash   = NULL,
        ref         = resolved
      ))
    }
    # Defensive: accept_refs is filtered to c("label","run") above; an
    # accept_refs entry outside that pair would land here.
    stop(sprintf(
      "%s(): internal error — accept_refs entry '%s' not handled.",
      caller, code$kind
    ), call. = FALSE)
  }

  # Character path. Validate shape, then route on extension.
  stopifnot(is.character(code), length(code) == 1L, nzchar(code))
  ext <- tolower(tools::file_ext(code))
  if (ext == "sql") {
    if (!accept_sql) {
      stop(sprintf(
        "%s(): SQL file staging is out of scope (v1).", caller
      ), call. = FALSE)
    }
    return(list(
      kind        = "sql_file",
      inline_mode = FALSE,
      step        = NA_character_,
      code_body   = NA_character_,
      code_hash   = NULL,
      ref         = NULL
    ))
  }

  if (!file.exists(code)) {
    stop(sprintf("%s(): file not found: %s", caller, code), call. = FALSE)
  }
  step      <- normalizePath(code, mustWork = TRUE)
  code_body <- paste(readLines(step, warn = FALSE), collapse = "\n")
  code_hash <- .mr_code_hash(step, list())
  list(
    kind        = "file",
    inline_mode = FALSE,
    step        = step,
    code_body   = code_body,
    code_hash   = code_hash,
    ref         = NULL
  )
}
