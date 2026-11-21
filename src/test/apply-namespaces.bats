#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for apply-namespaces: the namespaces stage is dry-run and applied
# ahead of the validation of everything else.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  NAMESPACES="${TEST_RUN_BASE}/work/stages/namespaces"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
}

teardown() {
  teardown_test_dirs
}

write_namespace() {
  local file="$1"
  local name="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "${name}" > "${file}"
}

@test "apply-namespaces does nothing when the stage does not exist" {
  run apply-namespaces
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
  grep -qF "No Namespaces to apply" "${TEST_RUN_BASE}/work/container.log"
}

@test "apply-namespaces does nothing when the stage holds no manifests" {
  mkdir -p "${NAMESPACES}/run-env-a"
  run apply-namespaces
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
}

@test "apply-namespaces refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  write_namespace "${NAMESPACES}/run-env-a/namespace.yaml" run-env-a
  run apply-namespaces
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy applies Namespaces, this is env"* ]]
  [ ! -f "${K_LOG}" ]
}

@test "apply-namespaces dry-runs every Namespace, then applies the stage" {
  write_namespace "${NAMESPACES}/run-env-a/namespace.yaml" run-env-a
  write_namespace "${NAMESPACES}/shared-namespace.yaml" shared
  run apply-namespaces
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "--dry-run=server" "${K_LOG}")" -eq 2 ]
  local last_dry_run applied
  last_dry_run=$(grep -n -- "--dry-run=server" "${K_LOG}" | tail -n 1 | cut -d: -f1)
  applied=$(grep -n -- "-R -f ${NAMESPACES}" "${K_LOG}" | cut -d: -f1)
  [ "${last_dry_run}" -lt "${applied}" ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply-namespaces.log" ]
}

@test "apply-namespaces dry-runs and applies under the environment's field manager" {
  write_namespace "${NAMESPACES}/run-env-a/namespace.yaml" run-env-a
  run apply-namespaces
  [ "$status" -eq 0 ]
  grep -qF -- "apply --dry-run=server --server-side --field-manager=kaptain/meta-env/run-platform-test -f ${NAMESPACES}/run-env-a/namespace.yaml" "${K_LOG}"
  grep -qF -- "apply --server-side --field-manager=kaptain/meta-env/run-platform-test -R -f ${NAMESPACES}" "${K_LOG}"
}

@test "apply-namespaces applies none of them when the cluster refuses one" {
  write_namespace "${NAMESPACES}/run-env-a/namespace.yaml" run-env-a
  write_namespace "${NAMESPACES}/run-env-b/namespace.yaml" run-env-b
  install_mock_k_failing_dry_run
  run apply-namespaces
  [ "$status" -ne 0 ]
  [[ "$output" == *"Namespaces refused by the cluster: 2/2, none applied"* ]]
  [[ "$output" == *"  - run-env-a/namespace.yaml"* ]]
  [[ "$output" == *"  - run-env-b/namespace.yaml"* ]]
  run grep -- "-R -f" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "apply-namespaces keeps what the cluster said about each dry-run" {
  write_namespace "${NAMESPACES}/run-env-a/namespace.yaml" run-env-a
  install_mock_k_failing_dry_run
  run apply-namespaces
  [ "$status" -ne 0 ]
  grep -q "validation error" "${TEST_RUN_BASE}/work/audit/validation/stages_namespaces_run-env-a_namespace.txt"
}

@test "apply-namespaces fails when the apply fails" {
  write_namespace "${NAMESPACES}/run-env-a/namespace.yaml" run-env-a
  cluster_fails apply
  run apply-namespaces
  [ "$status" -ne 0 ]
  [[ "$output" == *"Applying Namespaces failed"* ]]
}
