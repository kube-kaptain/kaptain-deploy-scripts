#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for manifest preparation, validation, and application scripts.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  copy_fixture_manifests
  # Create work subdirs that deploy normally creates
  mkdir -p "${TEST_RUN_BASE}/work/manifests"
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
}

teardown() {
  teardown_test_dirs
}

# prepare-manifests tests

@test "prepare-manifests copies manifests to work directory" {
  run prepare-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/manifests/configmap.yaml" ]
  [ -f "${TEST_RUN_BASE}/work/manifests/deployment.yaml" ]
}

@test "prepare-manifests fails if source dir missing" {
  rm -rf "${TEST_RUN_BASE}/manifests"
  run prepare-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "prepare-manifests fails if work dir missing" {
  rm -rf "${TEST_RUN_BASE}/work/manifests"
  run prepare-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# validate-manifests tests

@test "validate-manifests runs dry-run for each file" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q "apply --dry-run=server" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests creates audit files" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run validate-manifests
  [ "$status" -eq 0 ]
  [ -d "${TEST_RUN_BASE}/work/audit/validation" ]
  local count
  count=$(find "${TEST_RUN_BASE}/work/audit/validation" -name "*.txt" | wc -l)
  [ "${count}" -gt 0 ]
}

@test "validate-manifests fails with no manifests" {
  run validate-manifests
  [ "$status" -eq 43 ]
  [[ "$output" == *"No manifest files"* ]]
}

@test "validate-manifests reports validation failures" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"--dry-run"* ]]; then
  echo "validation error" >&2
  exit 1
fi
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run validate-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Validation failed"* ]]
}

# apply-manifests tests

@test "apply-manifests calls k apply" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  export ENVIRONMENT="test-env"
  run apply-manifests
  [ "$status" -eq 0 ]
  grep -q "apply -f" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "apply-manifests creates audit log" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  export ENVIRONMENT="test-env"
  run apply-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply.log" ]
}

@test "apply-manifests notifies on success" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  export ENVIRONMENT="test-env"
  run apply-manifests
  [ "$status" -eq 0 ]
  [[ "$output" == *"Manifests applied"* ]]
}

@test "apply-manifests reports failure" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  export ENVIRONMENT="test-env"
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"apply -f"* ]] && [[ "$*" != *"--dry-run"* ]]; then
  echo "apply error" >&2
  exit 1
fi
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run apply-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Apply failed"* ]]
}
