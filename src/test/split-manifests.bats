#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for split-manifests: setting aside the run-platform's own set and the
# child sets marked for seed-and-compare.

load test_helper

MARKER_NAME="run-environment-seed-and-compare-marker.yaml"
SELF_NAME="run-platform-self"

setup() {
  setup_test_dirs
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/manifests"
  WORK="${TEST_RUN_BASE}/work/manifests"
  SELF="${TEST_RUN_BASE}/work/self"
  SEED="${TEST_RUN_BASE}/work/seed"
  # Setting aside is a run-platform's job; the env cases set their own type.
  export ENVIRONMENT_TYPE="meta-env"
  export ENVIRONMENT="${SELF_NAME}"
}

teardown() {
  teardown_test_dirs
}

write_child_manifest() {
  local child="$1"
  mkdir -p "${WORK}/${child}"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "${child}" > "${WORK}/${child}/configmap.yaml"
}

mark_child() {
  local child="$1"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s-run-environment-seed-and-compare-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' "${child}" > "${WORK}/${child}/${MARKER_NAME}"
}

@test "split-manifests sets aside an unmarked run-platform's own set and nothing else" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  run split-manifests
  [ "$status" -eq 0 ]
  [ ! -e "${WORK}/${SELF_NAME}" ]
  [ -f "${SELF}/configmap.yaml" ]
  [ -f "${WORK}/app-one/configmap.yaml" ]
  [ ! -e "${SEED}" ]
  grep -qF "Set aside run-platform's own set: ${SELF_NAME} -> self" "${TEST_RUN_BASE}/work/container.log"
  ! grep -qF "Removed seed-and-compare marker" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "No seed-and-compare sets to set aside besides the run-platform's own" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests sets aside a marked run-platform's own set to self, not seed, without its marker" {
  write_child_manifest "${SELF_NAME}"
  mark_child "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SELF}/configmap.yaml" ]
  [ ! -e "${SELF}/${MARKER_NAME}" ]
  [ ! -e "${SEED}" ]
  grep -qF "Removed seed-and-compare marker from ${SELF_NAME}" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests fails a run-platform deploy without its own set, moving nothing" {
  write_child_manifest run-env-a
  mark_child run-env-a
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run-platform's own set does not exist: ${SELF_NAME}"* ]]
  [ -d "${WORK}/run-env-a" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${SEED}" ]
}

@test "split-manifests moves a marked child to the seed dir whole, without its marker" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: assembled\n' > "${WORK}/run-env-a/secret.yaml"
  run split-manifests
  [ "$status" -eq 0 ]
  [ ! -e "${WORK}/run-env-a" ]
  [ -f "${SEED}/run-env-a/configmap.yaml" ]
  [ -f "${SEED}/run-env-a/secret.yaml" ]
  [ ! -e "${SEED}/run-env-a/${MARKER_NAME}" ]
  [ -f "${WORK}/app-one/configmap.yaml" ]
  grep -qF "Set aside for seeding: run-env-a" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "Removed seed-and-compare marker from run-env-a" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests sets aside every marked child, the run-platform's own to self" {
  write_child_manifest run-env-a
  write_child_manifest run-env-b
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  mark_child run-env-a
  mark_child run-env-b
  mark_child "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -d "${SEED}/run-env-a" ]
  [ -d "${SEED}/run-env-b" ]
  [ ! -e "${SEED}/${SELF_NAME}" ]
  [ -f "${SELF}/configmap.yaml" ]
  [ -d "${WORK}/app-one" ]
  grep -qF "Set aside 2 seed-and-compare set(s)" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests fails on a marker at the top of the tree" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  printf 'kind: ConfigMap\n' > "${WORK}/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at the top of a child set: ${MARKER_NAME}"* ]]
  [ -d "${WORK}/${SELF_NAME}" ]
}

@test "split-manifests fails on a marker nested below a child's top" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mkdir -p "${WORK}/run-env-a/nested"
  printf 'kind: ConfigMap\n' > "${WORK}/run-env-a/nested/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at the top of a child set: run-env-a/nested/${MARKER_NAME}"* ]]
  [ -d "${WORK}/run-env-a" ]
  [ -d "${WORK}/${SELF_NAME}" ]
}

@test "split-manifests fails on a marker nested inside the run-platform's own set, moving nothing" {
  write_child_manifest "${SELF_NAME}"
  mkdir -p "${WORK}/${SELF_NAME}/nested"
  printf 'kind: ConfigMap\n' > "${WORK}/${SELF_NAME}/nested/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at the top of a child set: ${SELF_NAME}/nested/${MARKER_NAME}"* ]]
  [ -d "${WORK}/${SELF_NAME}" ]
  [ ! -e "${SELF}" ]
}

@test "split-manifests fails an environment deploy that holds a marker, moving nothing" {
  export ENVIRONMENT_TYPE="env"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Seed-and-compare marker in a env deploy: run-env-a/${MARKER_NAME}"* ]]
  [[ "$output" == *"Only a run-platform (meta-env) deploy sets aside seed-and-compare sets"* ]]
  [ -d "${WORK}/run-env-a" ]
  [ ! -e "${SEED}" ]
}

@test "split-manifests passes an environment deploy with no markers" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest app-one
  write_child_manifest run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${WORK}/app-one/configmap.yaml" ]
  [ -f "${WORK}/run-env-a/configmap.yaml" ]
  [ ! -e "${SELF}" ]
  grep -qF "No seed-and-compare sets to set aside" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests fails without ENVIRONMENT_TYPE" {
  unset ENVIRONMENT_TYPE
  write_child_manifest app-one
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENVIRONMENT_TYPE is required"* ]]
}

@test "split-manifests fails if the work dir is missing" {
  rm -rf "${WORK}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Manifests work directory does not exist"* ]]
}
