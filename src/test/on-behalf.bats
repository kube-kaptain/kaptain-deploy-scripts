#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for validate-on-behalf and apply-on-behalf: the cluster-scoped
# resources child environments have delegated to a run-platform, validated and
# applied under each child's own field manager.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  ON_BEHALF="${TEST_RUN_BASE}/cluster-scoped-on-behalf"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
}

teardown() {
  teardown_test_dirs
}

# A cluster-scoped resource a child has delegated, at a path within its dir
delegated() {
  local child="$1"
  local relative="$2"
  local kind="${3:-ClusterRole}"
  local file="${ON_BEHALF}/${child}/${relative}"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: %s\nmetadata:\n  name: %s:%s\n' \
    "${kind}" "${child}" "$(basename "${relative}" .yaml)" > "${file}"
}

# validate-on-behalf

@test "validate-on-behalf passes when nothing has been delegated" {
  run validate-on-behalf
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
  grep -qF "No child has delegated cluster-scoped resources" "${TEST_RUN_BASE}/work/container.log"
}

@test "validate-on-behalf refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  delegated run-omg vendor-thing/clusterrole.yaml
  run validate-on-behalf
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy validates resources delegated to it, this is env"* ]]
  [ ! -f "${K_LOG}" ]
}

@test "validate-on-behalf dry-runs each file under the field manager of the child that delegated it" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  delegated run-bravo vendor-thing/nested/clusterrolebinding.yaml ClusterRoleBinding
  run validate-on-behalf
  [ "$status" -eq 0 ]
  grep -qxF -- "apply --dry-run=server --server-side --field-manager=kaptain/env/run-alpha -f ${ON_BEHALF}/run-alpha/vendor-thing/clusterrole.yaml" "${K_LOG}"
  grep -qxF -- "apply --dry-run=server --server-side --field-manager=kaptain/env/run-bravo -f ${ON_BEHALF}/run-bravo/vendor-thing/nested/clusterrolebinding.yaml" "${K_LOG}"
  grep -qF "Validated 2 delegated cluster-scoped resource(s)" "${TEST_RUN_BASE}/work/container.log"
}

@test "validate-on-behalf never dry-runs under the run-platform's own field manager" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  run validate-on-behalf
  [ "$status" -eq 0 ]
  run grep -- "kaptain/meta-env/" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "validate-on-behalf changes nothing in the cluster" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  run validate-on-behalf
  [ "$status" -eq 0 ]
  run grep -v -- "--dry-run=server" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "validate-on-behalf reports every file the cluster refuses, and keeps what it said" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  delegated run-bravo vendor-thing/clusterrole.yaml
  install_mock_k_failing_dry_run
  run validate-on-behalf
  [ "$status" -ne 0 ]
  [[ "$output" == *"Delegated resources refused by the cluster: 2/2"* ]]
  [[ "$output" == *"  - run-alpha/vendor-thing/clusterrole.yaml"* ]]
  [[ "$output" == *"  - run-bravo/vendor-thing/clusterrole.yaml"* ]]
  grep -q "validation error" "${TEST_RUN_BASE}/work/audit/validation/on-behalf_run-alpha_vendor-thing_clusterrole.txt"
}

@test "validate-on-behalf fails on a delegated CRD before asking the cluster anything, naming the child to move it out of" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  delegated run-alpha vendor-thing/customresourcedefinition-widget.yaml CustomResourceDefinition
  run validate-on-behalf
  [ "$status" -eq 52 ]
  [[ "$output" == *"CRDs and Namespaces delegated by run-alpha: 1"* ]]
  [[ "$output" == *"CRDs and Namespaces belong to the cluster, not to an environment. Only the run-platform manages them. Move them out of run-alpha and into the run-platform:"* ]]
  [[ "$output" == *"  - vendor-thing/customresourcedefinition-widget.yaml (CustomResourceDefinition)"* ]]
  [ ! -f "${K_LOG}" ]
}

@test "validate-on-behalf fails on a delegated Namespace, and says so for each child that has one before failing" {
  delegated run-alpha vendor-thing/namespace.yaml Namespace
  delegated run-bravo vendor-thing/customresourcedefinition-widget.yaml CustomResourceDefinition
  delegated run-bravo vendor-thing/namespace.yaml Namespace
  run validate-on-behalf
  [ "$status" -eq 52 ]
  [[ "$output" == *"CRDs and Namespaces delegated by run-alpha: 1"* ]]
  [[ "$output" == *"Move them out of run-alpha and into the run-platform:"* ]]
  [[ "$output" == *"CRDs and Namespaces delegated by run-bravo: 2"* ]]
  [[ "$output" == *"Move them out of run-bravo and into the run-platform:"* ]]
  [[ "$output" == *"  - vendor-thing/namespace.yaml (Namespace)"* ]]
  [[ "$output" == *"  - vendor-thing/customresourcedefinition-widget.yaml (CustomResourceDefinition)"* ]]
  [ ! -f "${K_LOG}" ]
}

@test "validate-on-behalf fails on a delegated file that is not .yaml, which kubectl would apply unvalidated" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  cp "${ON_BEHALF}/run-alpha/vendor-thing/clusterrole.yaml" "${ON_BEHALF}/run-alpha/vendor-thing/sneaky.yml"
  run validate-on-behalf
  [ "$status" -eq 51 ]
  [[ "$output" == *"Files delegated to this run-platform that are not .yaml: 1"* ]]
  [[ "$output" == *"  - run-alpha/vendor-thing/sneaky.yml"* ]]
  [ ! -f "${K_LOG}" ]
}

# apply-on-behalf

@test "apply-on-behalf does nothing when nothing has been delegated" {
  run apply-on-behalf
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
}

@test "apply-on-behalf refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  delegated run-omg vendor-thing/clusterrole.yaml
  run apply-on-behalf
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy applies resources delegated to it, this is env"* ]]
  [ ! -f "${K_LOG}" ]
}

@test "apply-on-behalf applies each child's dir under that child's field manager" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  delegated run-bravo vendor-thing/clusterrole.yaml
  run apply-on-behalf
  [ "$status" -eq 0 ]
  grep -qxF -- "apply --server-side --field-manager=kaptain/env/run-alpha -R -f ${ON_BEHALF}/run-alpha" "${K_LOG}"
  grep -qxF -- "apply --server-side --field-manager=kaptain/env/run-bravo -R -f ${ON_BEHALF}/run-bravo" "${K_LOG}"
  [ "$(wc -l < "${K_LOG}")" -eq 2 ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply-on-behalf.log" ]
}

@test "apply-on-behalf never applies under the run-platform's own field manager, and never forces" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  run apply-on-behalf
  [ "$status" -eq 0 ]
  run grep -E -- "kaptain/meta-env/|--force-conflicts" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "apply-on-behalf goes one child at a time, in name order" {
  delegated run-bravo vendor-thing/clusterrole.yaml
  delegated run-alpha vendor-thing/clusterrole.yaml
  run apply-on-behalf
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "${K_LOG}")" == *"${ON_BEHALF}/run-alpha" ]]
  [[ "$(sed -n 2p "${K_LOG}")" == *"${ON_BEHALF}/run-bravo" ]]
}

@test "apply-on-behalf stops at a child whose apply fails, leaving the rest untouched" {
  delegated run-alpha vendor-thing/clusterrole.yaml
  delegated run-bravo vendor-thing/clusterrole.yaml
  cluster_fails apply
  run apply-on-behalf
  [ "$status" -ne 0 ]
  [[ "$output" == *"Applying the cluster-scoped resources run-alpha delegated failed"* ]]
  run grep -- "run-bravo" "${K_LOG}"
  [ "$status" -eq 1 ]
}
