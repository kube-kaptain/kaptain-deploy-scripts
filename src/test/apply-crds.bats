#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for apply-crds: the crds stage is dry-run, applied and waited on ahead
# of the validation of everything else.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  # No pause between rounds of asking, so the tests do not wait
  export CRD_ESTABLISHED_POLL="0"
  CRDS="${TEST_RUN_BASE}/work/stages/crds"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
}

# How many times the cluster was asked whether a CRD is Established
asked_about() {
  grep -c -- "^get customresourcedefinition $1 " "${K_LOG}" || true
}

teardown() {
  teardown_test_dirs
}

write_crd() {
  local file="$1"
  local name="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: %s\n' "${name}" > "${file}"
}

line_of() {
  grep -n -- "$1" "${K_LOG}" | head -n 1 | cut -d: -f1
}

@test "apply-crds does nothing when the stage does not exist" {
  run apply-crds
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
  grep -qF "No CRDs to apply" "${TEST_RUN_BASE}/work/container.log"
}

@test "apply-crds does nothing when the stage holds no manifests" {
  mkdir -p "${CRDS}/app-one"
  run apply-crds
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
}

@test "apply-crds refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  run apply-crds
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy applies CRDs, this is env"* ]]
  [ ! -f "${K_LOG}" ]
}

@test "apply-crds dry-runs every CRD, then applies the stage, then asks whether each is Established" {
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  write_crd "${CRDS}/app-two/nested/gadget-crd.yaml" gadgets.example.com
  run apply-crds
  [ "$status" -eq 0 ]
  local last_dry_run applied first_asked
  last_dry_run=$(grep -n -- "--dry-run=server" "${K_LOG}" | tail -n 1 | cut -d: -f1)
  applied=$(line_of "-R -f ${CRDS}")
  first_asked=$(line_of "^get customresourcedefinition ")
  [ "$(grep -c -- "--dry-run=server" "${K_LOG}")" -eq 2 ]
  [ "${last_dry_run}" -lt "${applied}" ]
  [ "${applied}" -lt "${first_asked}" ]
  [ "$(asked_about widgets.example.com)" -eq 1 ]
  [ "$(asked_about gadgets.example.com)" -eq 1 ]
  grep -qF "CRDs applied and established: 2" "${TEST_RUN_BASE}/work/container.log"
}

@test "apply-crds asks again only about the CRDs that are not Established yet" {
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  write_crd "${CRDS}/app-two/gadget-crd.yaml" gadgets.example.com
  crd_established_after gadgets.example.com 2
  run apply-crds
  [ "$status" -eq 0 ]
  [ "$(asked_about widgets.example.com)" -eq 1 ]
  [ "$(asked_about gadgets.example.com)" -eq 3 ]
}

@test "apply-crds dry-runs and applies under the environment's field manager" {
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  run apply-crds
  [ "$status" -eq 0 ]
  grep -qF -- "apply --dry-run=server --server-side --field-manager=kaptain/meta-env/run-platform-test -f ${CRDS}/app-one/widget-crd.yaml" "${K_LOG}"
  grep -qF -- "apply --server-side --field-manager=kaptain/meta-env/run-platform-test -R -f ${CRDS}" "${K_LOG}"
}

@test "apply-crds applies none of them when the cluster refuses one" {
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  write_crd "${CRDS}/app-two/gadget-crd.yaml" gadgets.example.com
  install_mock_k_failing_dry_run
  run apply-crds
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRDs refused by the cluster: 2/2, none applied"* ]]
  [[ "$output" == *"  - app-one/widget-crd.yaml"* ]]
  [[ "$output" == *"  - app-two/gadget-crd.yaml"* ]]
  run grep -- "-R -f" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "apply-crds keeps what the cluster said about each dry-run" {
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  install_mock_k_failing_dry_run
  run apply-crds
  [ "$status" -ne 0 ]
  grep -q "validation error" "${TEST_RUN_BASE}/work/audit/validation/stages_crds_app-one_widget-crd.txt"
}

@test "apply-crds fails when the apply fails" {
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  cluster_fails apply
  run apply-crds
  [ "$status" -ne 0 ]
  [[ "$output" == *"Applying CRDs failed"* ]]
}

@test "apply-crds fails when the wait runs out, naming only the CRDs still not Established" {
  export CRD_ESTABLISHED_WAIT="0"
  write_crd "${CRDS}/app-one/widget-crd.yaml" widgets.example.com
  write_crd "${CRDS}/app-two/gadget-crd.yaml" gadgets.example.com
  crd_established_after gadgets.example.com 99
  run apply-crds
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRDs applied but not Established within 0s: 1/2"* ]]
  [[ "$output" == *"  - gadgets.example.com"* ]]
  [[ "$output" != *"  - widgets.example.com"* ]]
}
