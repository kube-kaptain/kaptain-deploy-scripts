#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for the validate-container script.
# validate-container checks mount paths only (env vars are in validate-environment).

load test_helper

setup() {
  setup_test_dirs
  install_mock_notify
  # Cleanup config ships as a build-owned ConfigMap in the image: the policy
  # document plus the schema it was validated against, unpacked to files here.
  write_cleanup_policy_configmap
  install_mock_jv 0
}

teardown() {
  teardown_test_dirs
}

# Stand-in for the schema validator, recording the arguments it was called with
# so the call shape can be asserted. The real one is covered by validate-tooling.
install_mock_jv() {
  local exit_code="${1:-0}"
  cat > "${TEST_MOCK_BIN}/jv" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "\${RUN_BASE_PATH}/work/jv-calls.log"
exit ${exit_code}
MOCK
  chmod +x "${TEST_MOCK_BIN}/jv"
}

@test "validate-container passes with all requirements met" {
  # Create required passphrase file
  echo "test-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run validate-container
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
}

@test "validate-container fails when secret mount missing" {
  echo "test-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  rm -rf "${TEST_MOUNT_BASE}/secret"
  run validate-container
  [ "$status" -eq 44 ]
  [[ "$output" == *"Secret mount not found"* ]]
}

@test "validate-container fails when configmap mount missing" {
  echo "test-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  rmdir "${TEST_MOUNT_BASE}/configmap"
  run validate-container
  [ "$status" -eq 44 ]
  [[ "$output" == *"ConfigMap mount not found"* ]]
}

@test "validate-container fails when environmentPassphrase missing" {
  run validate-container
  [ "$status" -eq 44 ]
  [[ "$output" == *"environmentPassphrase not found"* ]]
}

@test "validate-container counts multiple failures" {
  rm -rf "${TEST_MOUNT_BASE}/secret"
  rmdir "${TEST_MOUNT_BASE}/configmap"
  run validate-container
  [ "$status" -eq 44 ]
  [[ "$output" == *"errors"* ]]
}

# =============================================================================
# Cleanup policy - extracted to work files, then validated against its schema
#
# The extraction is what later deploy scripts read; the validation is a second
# opinion on what the build already checked before packaging.
# =============================================================================

@test "validate-container extracts both cleanup policy keys to work files" {
  echo "test-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run validate-container
  [ "$status" -eq 0 ]
  [[ "$(cat "${RUN_BASE_PATH}/work/cleanup/cleanup-policy.yaml")" == *"kind: kubernetes-run-environment"* ]]
  [[ "$(cat "${RUN_BASE_PATH}/work/cleanup/kaptainpm-schema.json")" == *"json-schema.org"* ]]
}

@test "validate-container validates the extracted document against the extracted schema" {
  echo "test-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run validate-container
  [ "$status" -eq 0 ]
  [[ "$(cat "${RUN_BASE_PATH}/work/jv-calls.log")" == "${RUN_BASE_PATH}/work/cleanup/kaptainpm-schema.json ${RUN_BASE_PATH}/work/cleanup/cleanup-policy.yaml" ]]
}

@test "validate-container fails when the cleanup policy does not validate" {
  echo "test-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  install_mock_jv 1
  run validate-container
  [ "$status" -eq 44 ]
  [[ "$output" == *"does not validate against the schema"* ]]
}
