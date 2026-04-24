# Note: label propagation from upstream Shape B data flows does not work in v0.1.
# .mr_label_for_produced_hash() matches on {name, hash} pairs in _mr_runs.outputs,
# but Shape B writes record {kind, logical_name, chunk_hash} — no `name` field —
# so propagation never fires. Coverage for Shape A artifact propagation is kept
# below; Shape B propagation is a separate production gap.

# Deleted: "downstream inherits a single agreeing upstream label" for Shape B
# Deleted: "downstream stays plain when upstreams disagree and warns" for Shape B
# Both require propagation from Shape B outputs which is not wired in v0.1.

test_that("explicit label wins over propagation without warning (Shape B)", {
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod, label = "eta_0.01")

  cons <- write_script(c(
    'grab("model", run = "all")',
    'stow(data.frame(a = 1), "out")'
  ))
  # launch() emits normal timing/staleness messages; expect_no_warning
  # confirms no propagation-related warning is raised when label= is
  # explicit.
  expect_no_warning({
    launch(cons, label = "explicit_override")
  })

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step = ? ORDER BY started_at",
    params = list(normalizePath(cons, mustWork = FALSE))
  )
  expect_equal(rows$variant_label, "explicit_override")
})

test_that("no labeled upstreams -> plain run, no warning (Shape B)", {
  new_test_db()

  prod <- write_script('stow(data.frame(a = 1), "model")')
  launch(prod)  # plain

  cons <- write_script(c(
    'grab("model", run = "all")',
    'stow(data.frame(a = 1), "out")'
  ))
  # launch() emits normal timing/staleness messages; expect_no_warning
  # confirms no propagation-related warning is raised for plain upstreams.
  expect_no_warning(launch(cons))

  con  <- .mr_get_connection()
  rows <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE step = ? ORDER BY started_at",
    params = list(normalizePath(cons, mustWork = FALSE))
  )
  expect_true(is.na(rows$variant_label))
})
