test_that("variants() with no args lists all labels in the system", {
  new_test_db()

  s <- write_script('stow("out", data.frame(a = 1))')
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

  s1 <- write_script('stow("a", data.frame(x = 1))')
  s2 <- write_script('stow("b", data.frame(x = 1))')
  launch(s1, label = "alpha")
  launch(s2, label = "beta")

  df <- variants(script = normalizePath(s1))
  expect_equal(df$label, "alpha")
})

test_that("variants(name = ...) filters to labels that produced that name", {
  new_test_db()

  s1 <- write_script('stow("features", data.frame(v = 1))')
  s2 <- write_script('stow("other",    data.frame(v = 1))')
  launch(s1, label = "slow")
  launch(s2, label = "beta")

  df <- variants(name = "features")
  expect_equal(df$label, "slow")
})

test_that("variants() aggregates multiple runs of the same label", {
  new_test_db()

  s <- write_script('stow("out", data.frame(a = 1))')
  launch(s, label = "one")
  launch(s, label = "one")

  df <- variants()
  expect_equal(df$n_runs, 2L)
})

test_that("variants_unexplored(script) lists labeled upstreams not consumed by the script", {
  new_test_db()

  # Each variant must produce distinct data so their output hashes differ —
  # used_by_this_script is hash-based, and identical content would make all
  # three map to the same hash, making them indistinguishable.
  prod_slow <- write_script('stow("features", data.frame(v = 1:3))')
  prod_fast <- write_script('stow("features", data.frame(v = 1:6))')
  prod_huge <- write_script('stow("features", data.frame(v = 1:9))')
  launch(prod_slow, label = "slow")
  launch(prod_fast, label = "fast")
  launch(prod_huge, label = "huge")

  cons <- write_script(c(
    'f <- grab("features")',
    'stow("n", data.frame(n = nrow(f)))'
  ))
  launch(cons, rebind = list(features = mr_variant("slow")))

  df <- variants_unexplored(normalizePath(cons))
  expect_true(all(c("logical_name", "upstream_label", "upstream_hash",
                    "last_seen", "used_by_this_script") %in% names(df)))
  used <- df[df$used_by_this_script, , drop = FALSE]
  expect_equal(used$upstream_label, "slow")
  unused <- df[!df$used_by_this_script, , drop = FALSE]
  expect_setequal(unused$upstream_label, c("fast", "huge"))
})
