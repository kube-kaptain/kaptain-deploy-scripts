#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for the k (namespace-locked kubectl wrapper) script.
# k hardcodes /run/work/audit/kubectl for audit logs.
# k uses ${Environment} which is token-substituted at image build time.

load test_helper

setup() {
  setup_test_dirs
  install_mock_kubectl
  # k writes to /run/work/audit/kubectl (hardcoded)
  mkdir -p /run/work/audit/kubectl
  export Environment="test-namespace"
}

teardown() {
  rm -rf /run/work/audit/kubectl/*
  teardown_test_dirs
}

@test "k passes arguments through to kubectl with namespace" {
  run k get pods
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-namespace"* ]]
  [[ "$output" == *"get"* ]]
  [[ "$output" == *"pods"* ]]
}

@test "k creates audit log entry" {
  k get deployments
  local count
  count=$(ls /run/work/audit/kubectl/ | wc -l)
  [ "${count}" -ge 1 ]
}

@test "k logs the full command in audit file" {
  k apply -f /tmp/test.yaml
  local audit_file
  audit_file=$(ls -t /run/work/audit/kubectl/ | head -1)
  local content
  content=$(</run/work/audit/kubectl/"${audit_file}")
  [[ "${content}" == *"kubectl -n test-namespace apply -f /tmp/test.yaml"* ]]
}

@test "k forwards multiple arguments correctly" {
  run k get pods -o wide --show-labels
  [ "$status" -eq 0 ]
  [[ "$output" == *"get pods -o wide --show-labels"* ]]
}
