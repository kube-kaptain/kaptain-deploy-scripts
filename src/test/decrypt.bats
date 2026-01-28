#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load test_helper

setup() {
  setup_test_dirs
  copy_fixture_secrets
  install_mock_notify
}

teardown() {
  teardown_test_dirs
}

@test "decrypt-secret rejects files without known suffix" {
  echo "some content" > "${TEST_RUN_BASE}/secrets/unknown.xyz"
  run decrypt-secret "unknown.xyz" ".xyz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Decrypt provider not found"* ]]
}

@test "decrypt-secret rejects nonexistent file" {
  run decrypt-secret "nonexistent.sha256.aes256" ".sha256.aes256"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "decrypt-secret rejects wrong number of arguments" {
  run decrypt-secret "DbPassword.sha256.aes256"
  [ "$status" -eq 42 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "decrypt .sha256.aes256 produces correct output file" {
  run decrypt-secret "DbPassword.sha256.aes256" ".sha256.aes256"
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/DbPassword" ]
}

@test "decrypt .sha256.aes256 produces correct content" {
  decrypt-secret "DbPassword.sha256.aes256" ".sha256.aes256"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  [ "${result}" = "super-secret-db-pass-123" ]
}

@test "decrypt second secret file produces correct output" {
  run decrypt-secret "ApiKey.sha256.aes256" ".sha256.aes256"
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/ApiKey" ]
}

@test "decrypt second secret file produces correct content" {
  decrypt-secret "ApiKey.sha256.aes256" ".sha256.aes256"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/ApiKey")
  [ "${result}" = "sk-test-key-abc-456" ]
}

@test "decrypt fails with wrong passphrase" {
  echo "wrong-passphrase" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run decrypt-secret "DbPassword.sha256.aes256" ".sha256.aes256"
  [ "$status" -ne 0 ]
}

@test "decrypt fails with empty passphrase" {
  echo -n "" > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run decrypt-secret "DbPassword.sha256.aes256" ".sha256.aes256"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

@test "decrypt creates nested output directories" {
  mkdir -p "${TEST_RUN_BASE}/secrets/nested/path"
  cp "${FIXTURES_DIR}/secrets/DbPassword.sha256.aes256" "${TEST_RUN_BASE}/secrets/nested/path/"
  run decrypt-secret "nested/path/DbPassword.sha256.aes256" ".sha256.aes256"
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/nested/path/DbPassword" ]
}

# Decrypt provider type tests - each suffix/iteration count

@test "decrypt .sha256.aes256.10k produces correct content" {
  cp "${FIXTURES_DIR}/secrets/iterations/DbPassword.sha256.aes256.10k" "${TEST_RUN_BASE}/secrets/"
  decrypt-secret "DbPassword.sha256.aes256.10k" ".sha256.aes256.10k"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  [ "${result}" = "super-secret-db-pass-123" ]
}

@test "decrypt .sha256.aes256.100k produces correct content" {
  cp "${FIXTURES_DIR}/secrets/iterations/DbPassword.sha256.aes256.100k" "${TEST_RUN_BASE}/secrets/"
  decrypt-secret "DbPassword.sha256.aes256.100k" ".sha256.aes256.100k"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  [ "${result}" = "super-secret-db-pass-123" ]
}

@test "decrypt .sha256.aes256.600k produces correct content" {
  cp "${FIXTURES_DIR}/secrets/iterations/DbPassword.sha256.aes256.600k" "${TEST_RUN_BASE}/secrets/"
  decrypt-secret "DbPassword.sha256.aes256.600k" ".sha256.aes256.600k"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  [ "${result}" = "super-secret-db-pass-123" ]
}

@test "decrypt .sha256.aes256 forwards to .sha256.aes256.10k" {
  # The bare .sha256.aes256 suffix is a forwarder to .sha256.aes256.10k
  decrypt-secret "DbPassword.sha256.aes256" ".sha256.aes256"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  [ "${result}" = "super-secret-db-pass-123" ]
}

@test "decrypt .age produces correct content" {
  cp "${FIXTURES_DIR}/secrets/iterations/DbPassword.age" "${TEST_RUN_BASE}/secrets/"
  cp "${FIXTURES_DIR}/secrets/iterations/age-identity.key" "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  decrypt-secret "DbPassword.age" ".age"
  result=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  [ "${result}" = "super-secret-db-pass-123" ]
}
