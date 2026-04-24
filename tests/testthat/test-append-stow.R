test_that(".mr_recording_run_id returns NULL outside launch, run_id inside", {
  new_test_db()
  expect_null(.mr_recording_run_id())
  expect_null(.mr_recording_variant_label())

  .mr_start_recording(run_id = "run_fake_123", variant_label = "lm")
  expect_identical(.mr_recording_run_id(), "run_fake_123")
  expect_identical(.mr_recording_variant_label(), "lm")
  .mr_stop_recording()

  expect_null(.mr_recording_run_id())
  expect_null(.mr_recording_variant_label())
})
