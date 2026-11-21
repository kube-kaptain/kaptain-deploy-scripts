#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for validate-child-role-bindings and apply-child-role-bindings: a
# child's role binding in its own namespace goes through the script the
# run-platform build generates for that child, never through k.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  BINDINGS="${TEST_RUN_BASE}/work/child-role-binding"
  CALLS="${TEST_RUN_BASE}/work/role-binding-commands.log"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
}

teardown() {
  teardown_test_dirs
}

# What split-manifests leaves for a child that brings such a binding
child_brings_role_binding() {
  local child="$1"
  mkdir -p "${BINDINGS}/${child}"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: %s\n  namespace: %s\n' "${child}" "${child}" \
    > "${BINDINGS}/${child}/rolebinding.yaml"
}

# validate-child-role-bindings

@test "validate-child-role-bindings passes when no child brings a role binding" {
  run validate-child-role-bindings
  [ "$status" -eq 0 ]
  [ ! -f "${CALLS}" ]
}

@test "validate-child-role-bindings dry-runs a binding through the child's own script" {
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  run validate-child-role-bindings
  [ "$status" -eq 0 ]
  [ "$(<"${CALLS}")" = "k-run-omg-role-binding-only --dry-run ${BINDINGS}/run-omg/rolebinding.yaml" ]
}

@test "validate-child-role-bindings never sends the binding through k" {
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  run validate-child-role-bindings
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
}

@test "validate-child-role-bindings fails when the child's script is not in the image" {
  child_brings_role_binding run-omg
  run validate-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"k-run-omg-role-binding-only is not in this image"* ]]
}

@test "validate-child-role-bindings fails when the script refuses the binding" {
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  child_role_binding_script_refuses run-omg
  run validate-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"The run-omg role binding was refused: run-omg/rolebinding.yaml"* ]]
  grep -q "refused" "${TEST_RUN_BASE}/work/audit/validation/child-role-binding_run-omg_rolebinding.txt"
}

@test "validate-child-role-bindings reports every child's problem before failing" {
  child_brings_role_binding run-alpha
  child_brings_role_binding run-bravo
  install_child_role_binding_script run-bravo
  child_role_binding_script_refuses run-bravo
  run validate-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"k-run-alpha-role-binding-only is not in this image"* ]]
  [[ "$output" == *"The run-bravo role binding was refused"* ]]
}

@test "validate-child-role-bindings uses each child's own script for its own binding" {
  child_brings_role_binding run-alpha
  child_brings_role_binding run-bravo
  install_child_role_binding_script run-alpha
  install_child_role_binding_script run-bravo
  run validate-child-role-bindings
  [ "$status" -eq 0 ]
  grep -qxF "k-run-alpha-role-binding-only --dry-run ${BINDINGS}/run-alpha/rolebinding.yaml" "${CALLS}"
  grep -qxF "k-run-bravo-role-binding-only --dry-run ${BINDINGS}/run-bravo/rolebinding.yaml" "${CALLS}"
  [ "$(wc -l < "${CALLS}")" -eq 2 ]
}

@test "validate-child-role-bindings refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  run validate-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy validates child role bindings, this is env"* ]]
  [ ! -f "${CALLS}" ]
}

# apply-child-role-bindings

@test "apply-child-role-bindings refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  run apply-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy applies child role bindings, this is env"* ]]
  [ ! -f "${CALLS}" ]
}

@test "apply-child-role-bindings does nothing when no child brings a role binding" {
  run apply-child-role-bindings
  [ "$status" -eq 0 ]
  [ ! -f "${CALLS}" ]
}

@test "apply-child-role-bindings applies a binding through the child's own script" {
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  run apply-child-role-bindings
  [ "$status" -eq 0 ]
  [ "$(<"${CALLS}")" = "k-run-omg-role-binding-only ${BINDINGS}/run-omg/rolebinding.yaml" ]
  grep -qF "Applied the run-omg role binding in its own namespace" "${TEST_RUN_BASE}/work/container.log"
}

@test "apply-child-role-bindings never sends the binding through k" {
  child_brings_role_binding run-omg
  install_child_role_binding_script run-omg
  run apply-child-role-bindings
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
}

@test "apply-child-role-bindings applies each child's binding through that child's script" {
  child_brings_role_binding run-alpha
  child_brings_role_binding run-bravo
  install_child_role_binding_script run-alpha
  install_child_role_binding_script run-bravo
  run apply-child-role-bindings
  [ "$status" -eq 0 ]
  grep -qxF "k-run-alpha-role-binding-only ${BINDINGS}/run-alpha/rolebinding.yaml" "${CALLS}"
  grep -qxF "k-run-bravo-role-binding-only ${BINDINGS}/run-bravo/rolebinding.yaml" "${CALLS}"
}

@test "apply-child-role-bindings fails when the script refuses, and stops there" {
  child_brings_role_binding run-alpha
  child_brings_role_binding run-bravo
  install_child_role_binding_script run-alpha
  install_child_role_binding_script run-bravo
  child_role_binding_script_refuses run-alpha
  run apply-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"Applying the run-alpha role binding in its own namespace failed"* ]]
  run grep -- "k-run-bravo-role-binding-only" "${CALLS}"
  [ "$status" -eq 1 ]
}

@test "apply-child-role-bindings fails when the child's script is not in the image" {
  child_brings_role_binding run-omg
  run apply-child-role-bindings
  [ "$status" -ne 0 ]
  [[ "$output" == *"Applying the run-omg role binding in its own namespace failed"* ]]
}
