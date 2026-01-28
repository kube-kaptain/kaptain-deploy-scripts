#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for decrypt-secrets and assemble-secrets scripts.
# decrypt-secrets uses declare -A (bash 4+) - skip if not available.

load test_helper

setup() {
  setup_test_dirs
  install_mock_notify
  # Create work subdirs that deploy normally creates
  mkdir -p "${TEST_RUN_BASE}/work/decrypted"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
}

teardown() {
  teardown_test_dirs
}

# decrypt-secrets tests

@test "decrypt-secrets decrypts all secret files" {
  copy_fixture_secrets
  run decrypt-secrets
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/DbPassword" ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/ApiKey" ]
}

@test "decrypt-secrets produces correct content" {
  copy_fixture_secrets
  decrypt-secrets
  db_pass=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  api_key=$(<"${TEST_RUN_BASE}/work/decrypted/ApiKey")
  [ "${db_pass}" = "super-secret-db-pass-123" ]
  [ "${api_key}" = "sk-test-key-abc-456" ]
}

@test "decrypt-secrets handles empty secrets dir" {
  run decrypt-secrets
  [ "$status" -eq 0 ]
}

@test "decrypt-secrets fails if secrets dir missing" {
  rm -rf "${TEST_RUN_BASE}/secrets"
  run decrypt-secrets
  [ "$status" -eq 46 ]
  [[ "$output" == *"Secrets directory missing"* ]]
}

@test "decrypt-secrets fails with mixed suffixes" {
  copy_fixture_secrets
  echo "test" > "${TEST_RUN_BASE}/secrets/Mixed.age"
  run decrypt-secrets
  [ "$status" -eq 47 ]
  [[ "$output" == *"Mixed encryption suffixes"* ]]
}

@test "decrypt-secrets handles nested secret paths" {
  cp "${FIXTURES_DIR}/secrets/environmentPassphrase" "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  mkdir -p "${TEST_RUN_BASE}/secrets/nested/deep"
  cp "${FIXTURES_DIR}/secrets/DbPassword.sha256.aes256" "${TEST_RUN_BASE}/secrets/nested/deep/"
  run decrypt-secrets
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/nested/deep/DbPassword" ]
}

@test "decrypt-secrets reports decryption failures" {
  copy_fixture_secrets
  echo "corrupted" > "${TEST_RUN_BASE}/secrets/DbPassword.sha256.aes256"
  run decrypt-secrets
  [ "$status" -eq 49 ]
  [[ "$output" == *"failed to decrypt"* ]]
}

# assemble-secrets tests

@test "assemble-secrets substitutes tokens into templates" {
  mkdir -p "${TEST_RUN_BASE}/work/decrypted"
  mkdir -p "${TEST_RUN_BASE}/work/manifests"
  echo -n "super-secret-db-pass-123" > "${TEST_RUN_BASE}/work/decrypted/DbPassword"
  echo -n "sk-test-key-abc-456" > "${TEST_RUN_BASE}/work/decrypted/ApiKey"
  copy_fixture_templates
  cp "${TEST_RUN_BASE}/manifests/"*.template.yaml "${TEST_RUN_BASE}/work/manifests/"

  run assemble-secrets
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/manifests/secret.yaml" ]
  [ ! -f "${TEST_RUN_BASE}/work/manifests/secret.template.yaml" ]
}

@test "assemble-secrets produces correct substituted content" {
  mkdir -p "${TEST_RUN_BASE}/work/decrypted"
  mkdir -p "${TEST_RUN_BASE}/work/manifests"
  echo -n "super-secret-db-pass-123" > "${TEST_RUN_BASE}/work/decrypted/DbPassword"
  echo -n "sk-test-key-abc-456" > "${TEST_RUN_BASE}/work/decrypted/ApiKey"
  copy_fixture_templates
  cp "${TEST_RUN_BASE}/manifests/"*.template.yaml "${TEST_RUN_BASE}/work/manifests/"

  assemble-secrets
  result=$(<"${TEST_RUN_BASE}/work/manifests/secret.yaml")
  [[ "${result}" == *"super-secret-db-pass-123"* ]]
  [[ "${result}" == *"sk-test-key-abc-456"* ]]
}

@test "assemble-secrets handles no templates" {
  mkdir -p "${TEST_RUN_BASE}/work/manifests"
  run assemble-secrets
  [ "$status" -eq 0 ]
}
