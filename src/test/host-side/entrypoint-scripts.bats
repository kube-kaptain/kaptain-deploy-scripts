#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Host-side tests that run scripts as container entrypoint (PID 1).
# These tests catch issues that only manifest when PPID=0.
#
# Run from host with: bats src/test/host-side/entrypoint-scripts.bats
# Requires:
#   TEST_IMAGE - base image to use (e.g., ghcr.io/kube-kaptain/image/image-environment-base-trixie-slim:1.35.4)
#   SCRIPTS_DIR - path to scripts directory to mount

setup() {
  if [[ -z "${TEST_IMAGE:-}" ]]; then
    skip "TEST_IMAGE not set"
  fi
  if [[ -z "${SCRIPTS_DIR:-}" ]]; then
    skip "SCRIPTS_DIR not set"
  fi
}

# Helper to run script as container entrypoint with scripts mounted
run_as_entrypoint() {
  docker run --rm \
    -v "${SCRIPTS_DIR}:/run/bin:ro" \
    -e "PATH=/run/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

# --- notify-*-echo scripts ---

@test "notify-info-echo produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/notify-info-echo "entrypoint test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"entrypoint test"* ]]
}

@test "notify-error-echo produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/notify-error-echo "error test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"error test"* ]]
}

@test "notify-warning-echo produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/notify-warning-echo "warning test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning test"* ]]
}

# --- notify-* dispatcher scripts ---

@test "notify-info produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/notify-info "info dispatch test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"info dispatch test"* ]]
}

@test "notify-error produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/notify-error "error dispatch test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"error dispatch test"* ]]
}

@test "notify-warning produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/notify-warning "warning dispatch test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning dispatch test"* ]]
}

# --- alert-echo script ---

@test "alert-echo produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/alert-echo "alert test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alert test"* ]]
}

# --- alert dispatcher script ---

@test "alert produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/alert "alert dispatch test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alert dispatch test"* ]]
}

# --- log script ---

@test "log produces output as entrypoint" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/log "log test"
  [ "$status" -eq 0 ]
  [[ "$output" == *"log test"* ]]
}

# --- validate-* scripts (expected failures with visible output) ---

@test "validate-environment shows errors when env missing" {
  run run_as_entrypoint "${TEST_IMAGE}" /run/bin/validate-environment
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be set"* ]]
}

@test "validate-container shows errors when mounts missing" {
  run docker run --rm \
    -v "${SCRIPTS_DIR}:/run/bin:ro" \
    -e "PATH=/run/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e "MOUNT_BASE_PATH=/nonexistent" \
    "${TEST_IMAGE}" /run/bin/validate-container
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
