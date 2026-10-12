#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for the apply and apply-force entry points.
# Both take one file or one directory and hand it to k, nothing else.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  copy_fixture_manifests
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="test-env"
  export ENVIRONMENT_TYPE="env"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
  MANIFEST="${TEST_RUN_BASE}/manifests/configmap.yaml"
}

teardown() {
  teardown_test_dirs
}

@test "apply applies a file under the environment field manager" {
  run apply "${MANIFEST}"
  [ "$status" -eq 0 ]
  grep -q "apply --server-side --field-manager=kaptain/env/test-env -R -f ${MANIFEST}" "${K_LOG}"
}

@test "apply applies a directory" {
  run apply "${TEST_RUN_BASE}/manifests"
  [ "$status" -eq 0 ]
  grep -q "apply --server-side --field-manager=kaptain/env/test-env -R -f ${TEST_RUN_BASE}/manifests" "${K_LOG}"
}

@test "apply never forces conflicts" {
  run apply "${MANIFEST}"
  [ "$status" -eq 0 ]
  ! grep -q -- "--force-conflicts" "${K_LOG}"
}

@test "apply-force forces conflicts" {
  run apply-force "${MANIFEST}"
  [ "$status" -eq 0 ]
  grep -q "apply --server-side --field-manager=kaptain/env/test-env --force-conflicts -R -f ${MANIFEST}" "${K_LOG}"
}

@test "apply-force applies a directory" {
  run apply-force "${TEST_RUN_BASE}/manifests"
  [ "$status" -eq 0 ]
  grep -q -- "--force-conflicts -R -f ${TEST_RUN_BASE}/manifests" "${K_LOG}"
}

@test "apply passes through the exit code from k" {
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
exit 17
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"
  run apply "${MANIFEST}"
  [ "$status" -eq 17 ]
}

@test "apply fails without a path" {
  run apply
  [ "$status" -ne 0 ]
  [ ! -f "${K_LOG}" ]
}
