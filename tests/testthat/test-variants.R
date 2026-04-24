test_that("variants() with no args lists all labels in the system", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "one")
  launch(s, label = "two")
  launch(s)  # plain run, should not appear

  df <- variants()
  expect_setequal(df$label, c("one", "two"))
  expect_true(all(c("script", "label", "first_seen", "last_seen",
                    "n_runs", "latest_run_id") %in% names(df)))
})

test_that("variants(script = ...) filters to one script", {
  new_test_db()

  s1 <- write_script('stow(data.frame(x = 1), "a")')
  s2 <- write_script('stow(data.frame(x = 1), "b")')
  launch(s1, label = "alpha")
  launch(s2, label = "beta")

  df <- variants(script = normalizePath(s1))
  expect_equal(df$label, "alpha")
})

test_that("variants(name = ...) filters to labels that produced that name", {
  new_test_db()

  s1 <- write_script('stow(data.frame(v = 1), "features")')
  s2 <- write_script('stow(data.frame(v = 1),    "other")')
  launch(s1, label = "slow")
  launch(s2, label = "beta")

  df <- variants(name = "features")
  expect_equal(df$label, "slow")
})

test_that("variants() aggregates multiple runs of the same label", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "one")
  launch(s, label = "one")

  df <- variants()
  expect_equal(df$n_runs, 2L)
})

# Deleted: "variants_unexplored lists labeled upstreams not consumed by the script"
# variants_unexplored() matches on p$name in _mr_runs.outputs JSON; Shape B
# writes produce {kind, logical_name, ...} — no p$name field — so the function
# returns 0 rows for Shape B data flows. Surfaced as a production gap for a
# separate fix alongside the label-propagation issue.
