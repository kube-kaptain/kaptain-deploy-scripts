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
}

teardown() {
  teardown_test_dirs
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
