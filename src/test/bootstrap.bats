#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for bootstrap: offline preparation of a run-platform's own manifests
# into the mounted output directory.

load test_helper

MARKER_NAME="run-environment-seed-and-compare-marker.yaml"
SELF_NAME="run-platform-test"

setup() {
  setup_test_dirs
  install_mock_notify
  copy_fixture_secrets
  # bootstrap runs the real validate-environment, which requires this ConfigMap
  write_cleanup_policy_configmap
  export ENVIRONMENT="${SELF_NAME}"
  export ENVIRONMENT_TYPE="meta-env"
  export VERSION="v1.0.0"
  export DEPLOY_MODE="job"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
  MANIFESTS="${TEST_RUN_BASE}/manifests"
  OUT="${TEST_RUN_BASE}/bootstrap"
  mkdir -p "${OUT}"
  # The run-platform's own set, with a secret to assemble
  mkdir -p "${MANIFESTS}/${SELF_NAME}"
  cp "${FIXTURES_DIR}/manifests/configmap.yaml" "${MANIFESTS}/${SELF_NAME}/"
  cp "${FIXTURES_DIR}/templates/secret.template.yaml" "${MANIFESTS}/${SELF_NAME}/"
  # A child environment's deployer, marked for seed-and-compare
  mkdir -p "${MANIFESTS}/run-env-child"
  cp "${FIXTURES_DIR}/manifests/deployment.yaml" "${MANIFESTS}/run-env-child/"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: run-env-child-run-environment-seed-and-compare-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' \
    > "${MANIFESTS}/run-env-child/${MARKER_NAME}"
}

teardown() {
  teardown_test_dirs
}

@test "bootstrap writes the run-platform's own set, secrets assembled, to the output" {
  run bootstrap
  [ "$status" -eq 0 ]
  [ -f "${OUT}/configmap.yaml" ]
  [ -f "${OUT}/secret.yaml" ]
  [ ! -e "${OUT}/secret.template.yaml" ]
  [[ "$(<"${OUT}/secret.yaml")" == *"super-secret-db-pass-123"* ]]
  [[ "$(<"${OUT}/secret.yaml")" == *"sk-test-key-abc-456"* ]]
  [[ "$output" == *"Bootstrap of ${SELF_NAME} version v1.0.0 complete: 2 manifest files in ${OUT}"* ]]
  [[ "$output" == *"plain text"* ]]
}

@test "bootstrap writes only the run-platform's own set to the output" {
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(find "${OUT}" -type f | wc -l)" -eq 2 ]
  [ ! -e "${OUT}/${MARKER_NAME}" ]
  [ ! -e "${OUT}/deployment.yaml" ]
  [ ! -e "${OUT}/run-env-child" ]
  [ ! -e "${OUT}/kaptain-environment-cleanup-policy.yaml" ]
  [ ! -e "${OUT}/decrypted" ]
}

@test "bootstrap removes the marker from a marked run-platform's own set" {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: self-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' \
    > "${MANIFESTS}/${SELF_NAME}/${MARKER_NAME}"
  run bootstrap
  [ "$status" -eq 0 ]
  [ ! -e "${OUT}/${MARKER_NAME}" ]
  [ -f "${OUT}/configmap.yaml" ]
}

@test "bootstrap refuses an environment image" {
  export ENVIRONMENT="run-test-env"
  export ENVIRONMENT_TYPE="env"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) image bootstraps, this is env"* ]]
  [ -z "$(ls -A "${OUT}")" ]
}

@test "bootstrap fails when validate-environment fails" {
  unset VERSION
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"VERSION must be set"* ]]
  [ -z "$(ls -A "${OUT}")" ]
}

@test "bootstrap fails without the environment passphrase mounted" {
  rm "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Environment passphrase not mounted: ${TEST_MOUNT_BASE}/secret/environmentPassphrase"* ]]
  [ -z "$(ls -A "${OUT}")" ]
}

@test "bootstrap fails without the output directory mounted" {
  rmdir "${OUT}"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bootstrap output directory not mounted: ${OUT}"* ]]
  [ ! -e "${OUT}" ]
}

@test "bootstrap fails on a .yaml already in the output directory, touching nothing in it" {
  printf 'keep me\n' > "${OUT}/existing.yaml"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bootstrap output directory already holds manifests: ${OUT}"* ]]
  [[ "$output" == *"${OUT}/existing.yaml"* ]]
  [ "$(ls -A "${OUT}")" = "existing.yaml" ]
  [ "$(<"${OUT}/existing.yaml")" = "keep me" ]
}

@test "bootstrap fails on a nested .yml in the output directory" {
  mkdir -p "${OUT}/nested/deeper"
  printf 'keep me\n' > "${OUT}/nested/deeper/existing.yml"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bootstrap output directory already holds manifests: ${OUT}"* ]]
  [[ "$output" == *"${OUT}/nested/deeper/existing.yml"* ]]
  [ ! -e "${OUT}/configmap.yaml" ]
}

@test "bootstrap ignores files in the output directory that are not manifests" {
  printf 'finder\n' > "${OUT}/.DS_Store"
  mkdir -p "${OUT}/notes"
  printf 'keep me\n' > "${OUT}/notes/README.md"
  run bootstrap
  [ "$status" -eq 0 ]
  [ -f "${OUT}/configmap.yaml" ]
  [ -f "${OUT}/secret.yaml" ]
  [ "$(<"${OUT}/.DS_Store")" = "finder" ]
  [ "$(<"${OUT}/notes/README.md")" = "keep me" ]
}

@test "bootstrap fails with the wrong passphrase, writing nothing" {
  printf 'wrong-passphrase' > "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to decrypt"* ]]
  [ -z "$(ls -A "${OUT}")" ]
}

@test "bootstrap fails without the run-platform's own set, writing nothing" {
  rm -rf "${MANIFESTS:?}/${SELF_NAME}"
  run bootstrap
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run-platform's own set does not exist: ${SELF_NAME}"* ]]
  [ -z "$(ls -A "${OUT}")" ]
}
