#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for the validate-environment script.
# validate-environment checks required env vars are set.

load test_helper

setup() {
  setup_test_dirs
  install_mock_notify
  export DEPLOY_MODE="job"
  export ENVIRONMENT="test-env"
  export VERSION="v1.0.0"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
}

teardown() {
  teardown_test_dirs
}

@test "validate-environment passes with all requirements met" {
  run validate-environment
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
}

@test "validate-environment fails when DEPLOY_MODE is unset" {
  unset DEPLOY_MODE
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"DEPLOY_MODE must be set"* ]]
}

@test "validate-environment fails when DEPLOY_MODE is invalid" {
  export DEPLOY_MODE="invalid"
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"DEPLOY_MODE must be 'deployment' or 'job'"* ]]
}

@test "validate-environment passes with DEPLOY_MODE=deployment" {
  export DEPLOY_MODE="deployment"
  run validate-environment
  [ "$status" -eq 0 ]
}

@test "validate-environment passes with DEPLOY_MODE=job" {
  export DEPLOY_MODE="job"
  run validate-environment
  [ "$status" -eq 0 ]
}

@test "validate-environment fails when ENVIRONMENT is unset" {
  unset ENVIRONMENT
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"ENVIRONMENT must be set"* ]]
}

@test "validate-environment fails when VERSION is unset" {
  unset VERSION
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"VERSION must be set"* ]]
}

@test "validate-environment fails when TOKEN_DELIMITER_STYLE is unset" {
  unset TOKEN_DELIMITER_STYLE
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"TOKEN_DELIMITER_STYLE must be set"* ]]
}

@test "validate-environment fails when TOKEN_NAME_STYLE is unset" {
  unset TOKEN_NAME_STYLE
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"TOKEN_NAME_STYLE must be set"* ]]
}

@test "validate-environment counts multiple failures" {
  unset DEPLOY_MODE
  unset ENVIRONMENT
  unset VERSION
  unset TOKEN_DELIMITER_STYLE
  unset TOKEN_NAME_STYLE
  run validate-environment
  [ "$status" -eq 44 ]
  [[ "$output" == *"errors"* ]]
}
