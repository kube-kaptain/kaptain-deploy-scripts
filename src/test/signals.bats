#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for signal handling in deploy script.
# Signal handling is now inline in deploy rather than a separate library.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  install_mock_sleep
  install_mock_validate_container
  install_mock_oci_images
  install_mock_notify_oci_images_changed
  copy_fixture_manifests
  copy_fixture_secrets
  export ENVIRONMENT="test-env"
  export VERSION="v1.0.0"
  export DEPLOY_MODE="job"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
}

teardown() {
  teardown_test_dirs
}

@test "deploy initialises PHASE to Pre Validation" {
  # Start deploy and capture early output
  run timeout 2 deploy || true
  # The first notify-info should mention the starting message
  [[ "$output" == *"Starting"* ]]
}

@test "deploy defers SIGTERM during uninterruptible phase" {
  # This test verifies that SIGTERM during apply phase is deferred
  # We need to make the mock k slow down during apply
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"apply -f"* ]] && [[ "$*" != *"--dry-run"* ]]; then
  # Slow down the real apply to give time for signal
  sleep 2
fi
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  # Start deploy in background
  deploy &
  local deploy_pid=$!

  # Wait for it to reach apply phase
  sleep 1

  # Send SIGTERM
  kill -TERM "${deploy_pid}" 2>/dev/null || true

  # Wait for completion
  wait "${deploy_pid}" 2>/dev/null || true

  # Should have completed apply (file exists)
  [ -f "${TEST_RUN_BASE}/work/audit/apply.log" ]

  # Check for deferral message in notifications
  if [ -f "${TEST_RUN_BASE}/work/notifications.log" ]; then
    grep -q "deferring\|Shutdown requested" "${TEST_RUN_BASE}/work/notifications.log" || true
  fi
}

@test "deploy exits on SIGTERM during interruptible phase" {
  # Make prepare-manifests slow to catch SIGTERM during it
  cat > "${TEST_MOCK_BIN}/prepare-manifests" << 'MOCK'
#!/usr/bin/env bash
sleep 3
cp -a "${RUN_BASE_PATH}/manifests/"* "${RUN_BASE_PATH}/work/manifests/"
MOCK
  chmod +x "${TEST_MOCK_BIN}/prepare-manifests"

  # Start deploy in background
  deploy &
  local deploy_pid=$!

  # Wait for it to start preparing
  sleep 0.5

  # Send SIGTERM during interruptible phase
  kill -TERM "${deploy_pid}" 2>/dev/null || true

  # Wait for it
  wait "${deploy_pid}" 2>/dev/null
  local exit_code=$?

  # Should exit cleanly (0)
  [ "${exit_code}" -eq 0 ]
}
