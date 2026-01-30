#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for notify-*-echo scripts.
# These are the built-in echo providers that output to stdout/stderr.
# Must work even when PPID=0 (container init process) or ps fails.

SCRIPTS_DIR="/run/bin"

@test "notify-info-echo produces output with message" {
  run "${SCRIPTS_DIR}/notify-info-echo" "test message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test message"* ]]
}

@test "notify-info-echo includes timestamp" {
  run "${SCRIPTS_DIR}/notify-info-echo" "test message"
  [ "$status" -eq 0 ]
  # ISO 8601 timestamp format: YYYY-MM-DDTHH:MM:SSZ
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

@test "notify-info-echo fails without message" {
  run "${SCRIPTS_DIR}/notify-info-echo"
  [ "$status" -eq 42 ]
}

@test "notify-error-echo produces output with message" {
  run "${SCRIPTS_DIR}/notify-error-echo" "error message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"error message"* ]]
}

@test "notify-error-echo includes ERROR label" {
  run "${SCRIPTS_DIR}/notify-error-echo" "error message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "notify-error-echo fails without message" {
  run "${SCRIPTS_DIR}/notify-error-echo"
  [ "$status" -eq 42 ]
}

@test "notify-warning-echo produces output with message" {
  run "${SCRIPTS_DIR}/notify-warning-echo" "warning message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning message"* ]]
}

@test "notify-warning-echo includes WARNING label" {
  run "${SCRIPTS_DIR}/notify-warning-echo" "warning message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}

@test "notify-warning-echo fails without message" {
  run "${SCRIPTS_DIR}/notify-warning-echo"
  [ "$status" -eq 42 ]
}

@test "alert-echo produces output with message" {
  run "${SCRIPTS_DIR}/alert-echo" "alert message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alert message"* ]]
}

@test "alert-echo includes ALERT label" {
  run "${SCRIPTS_DIR}/alert-echo" "alert message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALERT"* ]]
}

@test "alert-echo includes timestamp" {
  run "${SCRIPTS_DIR}/alert-echo" "alert message"
  [ "$status" -eq 0 ]
  # ISO 8601 timestamp format: YYYY-MM-DDTHH:MM:SSZ
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

@test "alert-echo fails without message" {
  run "${SCRIPTS_DIR}/alert-echo"
  [ "$status" -eq 42 ]
}

@test "log produces output with message" {
  run "${SCRIPTS_DIR}/log" "log message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"log message"* ]]
}

@test "log fails without message" {
  run "${SCRIPTS_DIR}/log"
  [ "$status" -eq 42 ]
}

# --- notify-* dispatcher scripts (fan out to providers) ---

@test "notify-info produces output with message" {
  run "${SCRIPTS_DIR}/notify-info" "info message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"info message"* ]]
}

@test "notify-info includes timestamp" {
  run "${SCRIPTS_DIR}/notify-info" "info message"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
}

@test "notify-info fails without message" {
  run "${SCRIPTS_DIR}/notify-info"
  [ "$status" -eq 42 ]
}

@test "notify-error produces output with message" {
  run "${SCRIPTS_DIR}/notify-error" "error message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"error message"* ]]
}

@test "notify-error includes ERROR label" {
  run "${SCRIPTS_DIR}/notify-error" "error message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "notify-error fails without message" {
  run "${SCRIPTS_DIR}/notify-error"
  [ "$status" -eq 42 ]
}

@test "notify-warning produces output with message" {
  run "${SCRIPTS_DIR}/notify-warning" "warning message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning message"* ]]
}

@test "notify-warning includes WARNING label" {
  run "${SCRIPTS_DIR}/notify-warning" "warning message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}

@test "notify-warning fails without message" {
  run "${SCRIPTS_DIR}/notify-warning"
  [ "$status" -eq 42 ]
}

@test "alert produces output with message" {
  run "${SCRIPTS_DIR}/alert" "alert dispatch message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alert dispatch message"* ]]
}

@test "alert includes ALERT label" {
  run "${SCRIPTS_DIR}/alert" "alert dispatch message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALERT"* ]]
}

@test "alert fails without message" {
  run "${SCRIPTS_DIR}/alert"
  [ "$status" -eq 42 ]
}

# Tests for PID 1 scenario (container init process)
# When a script runs as PID 1, PPID=0 which causes ps to fail
# These tests verify the scripts handle grandparent_pid=0 gracefully
# Note: Real entrypoint tests are in host-side/entrypoint-scripts.bats

@test "notify-info-echo works when run as container entrypoint" {
  # When run as PID 1, PPID=0, grandparent lookup fails
  # Simulate by calling from minimal process chain where grandparent is PID 1
  run bash -c 'exec bash -c "exec /run/bin/notify-info-echo \"entrypoint test\""'
  [ "$status" -eq 0 ]
  [[ "$output" == *"entrypoint test"* ]]
}

@test "notify-error-echo works when run as container entrypoint" {
  run bash -c 'exec bash -c "exec /run/bin/notify-error-echo \"entrypoint error\""'
  [ "$status" -eq 0 ]
  [[ "$output" == *"entrypoint error"* ]]
}

@test "notify-info works when run as container entrypoint" {
  run bash -c 'exec bash -c "exec /run/bin/notify-info \"dispatcher test\""'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatcher test"* ]]
}

@test "notify-error works when run as container entrypoint" {
  run bash -c 'exec bash -c "exec /run/bin/notify-error \"dispatcher error\""'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatcher error"* ]]
}

# Tests for validation scripts that use notify-* internally
# These should produce visible output even when they fail validation

@test "validate-environment produces error output when env vars missing" {
  # Unset required vars - validation SHOULD fail with visible error messages
  unset DEPLOY_MODE ENVIRONMENT VERSION TOKEN_DELIMITER_STYLE TOKEN_NAME_STYLE
  run bash -c 'exec /run/bin/validate-environment'
  # Should fail (exit 44) but with visible output
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be set"* ]]
}

@test "validate-container produces error output when mounts missing" {
  # No mounts configured - validation SHOULD fail with visible error messages
  export MOUNT_BASE_PATH="/nonexistent"
  run bash -c 'exec /run/bin/validate-container'
  # Should fail but with visible output
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

