test_that("prune_variants(script, label) deletes matching _mr_runs rows", {
  new_test_db()

  s <- write_script('stow(data.frame(v = 1), "features")')
  launch(s, label = "slow")
  launch(s, label = "slow")
  launch(s, label = "fast")

  prune_variants(normalizePath(s), "slow")

  con <- .mr_get_connection()
  remaining <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE variant_label IS NOT NULL"
  )
  expect_equal(remaining$variant_label, "fast")
})

test_that("prune_variants(dry_run = TRUE) does not delete", {
  new_test_db()

  s <- write_script('stow(data.frame(a = 1), "out")')
  launch(s, label = "keepme")

  prune_variants(normalizePath(s), "keepme", dry_run = TRUE)

  con <- .mr_get_connection()
  n <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM _mr_runs
                              WHERE variant_label = 'keepme'")$n
  expect_equal(as.integer(n), 1L)
})

test_that("prune_variants requires both script and label", {
  expect_error(prune_variants("x.R"), regexp = "label",  fixed = FALSE)
  expect_error(prune_variants(label = "x"), regexp = "script", fixed = FALSE)
})

test_that("prune_variants leaves downstream labeled variants alone (append-shape)", {
  new_test_db()

  prod <- write_script('stow(data.frame(v = 1:4), "features")')
  launch(prod, label = "slow")

  cons <- write_script(c(
    'f <- grab("features")',
    'stow(data.frame(n = nrow(f)), "n")'
  ))
  launch(cons, rebind = list(features = mr_variant("slow")), label = "down")

  prune_variants(normalizePath(prod), "slow")

  con <- .mr_get_connection()
  remaining <- DBI::dbGetQuery(
    con, "SELECT variant_label FROM _mr_runs WHERE variant_label IS NOT NULL"
  )
  expect_equal(remaining$variant_label, "down")
})
