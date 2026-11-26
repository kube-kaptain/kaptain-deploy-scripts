#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for split-manifests: copying every manifest out of the complete tree
# into the dir of the step that applies it, leaving the tree complete.

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
  STAGES="${TEST_RUN_BASE}/work/stages"
  DEPLOY="${STAGES}/deploy"
  # Self and seed sets are a run-platform's; the env cases set their own type.
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

write_top_level_manifest() {
  local name="$1"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "${name}" > "${WORK}/${name}.yaml"
}

mark_child() {
  local child="$1"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s-run-environment-seed-and-compare-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' "${child}" > "${WORK}/${child}/${MARKER_NAME}"
}

# Every file under a dir, relative to it, sorted
files_in() {
  (cd "$1" && find . -type f | sort)
}

# The complete tree is never moved out of

@test "split-manifests leaves the complete tree in place on a run-platform deploy" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  write_top_level_manifest kaptain-environment-cleanup-policy
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${WORK}/${SELF_NAME}/configmap.yaml" ]
  [ -f "${WORK}/app-one/configmap.yaml" ]
  [ -f "${WORK}/run-env-a/configmap.yaml" ]
  [ -f "${WORK}/kaptain-environment-cleanup-policy.yaml" ]
}

@test "split-manifests leaves the complete tree in place on an environment deploy" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest app-one
  write_top_level_manifest kaptain-environment-cleanup-policy
  local before
  before=$(files_in "${WORK}")
  run split-manifests
  [ "$status" -eq 0 ]
  [ "$(files_in "${WORK}")" = "${before}" ]
}

@test "split-manifests deletes the markers from the complete tree and from the copies" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child "${SELF_NAME}"
  mark_child run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  [ -z "$(find "${TEST_RUN_BASE}/work" -name "${MARKER_NAME}")" ]
  grep -qF "Removed seed-and-compare marker from ${SELF_NAME}" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "Removed seed-and-compare marker from run-env-a" "${TEST_RUN_BASE}/work/container.log"
}

# Where each set is copied to

@test "split-manifests copies an unmarked run-platform's own set to self and nothing to seed" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SELF}/configmap.yaml" ]
  [ ! -e "${DEPLOY}/${SELF_NAME}" ]
  [ ! -e "${SEED}" ]
  grep -qF "Run-platform's own set: ${SELF_NAME} -> self" "${TEST_RUN_BASE}/work/container.log"
  ! grep -qF "Removed seed-and-compare marker" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests copies a marked run-platform's own set to self, not seed" {
  write_child_manifest "${SELF_NAME}"
  mark_child "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SELF}/configmap.yaml" ]
  [ ! -e "${SEED}" ]
  [ ! -e "${DEPLOY}/${SELF_NAME}" ]
}

@test "split-manifests copies a marked child to the seed dir whole" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: assembled\n' > "${WORK}/run-env-a/secret.yaml"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SEED}/run-env-a/configmap.yaml" ]
  [ -f "${SEED}/run-env-a/secret.yaml" ]
  [ ! -e "${DEPLOY}/run-env-a" ]
  grep -qF "Seed-and-compare set: run-env-a -> seed/run-env-a" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests copies every marked child to seed, the run-platform's own to self" {
  write_child_manifest run-env-a
  write_child_manifest run-env-b
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  mark_child run-env-a
  mark_child run-env-b
  mark_child "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SEED}/run-env-a/configmap.yaml" ]
  [ -f "${SEED}/run-env-b/configmap.yaml" ]
  [ ! -e "${SEED}/${SELF_NAME}" ]
  [ -f "${SELF}/configmap.yaml" ]
  grep -qF "Split complete: the run-platform's own set to self, 2 seed-and-compare set(s) to seed, the rest to the stages" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests copies everything else to stages/deploy" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-unmarked
  write_child_manifest run-env-a
  mark_child run-env-a
  write_top_level_manifest kaptain-environment-cleanup-policy
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/app-one/configmap.yaml" ]
  [ -f "${DEPLOY}/run-env-unmarked/configmap.yaml" ]
  [ -f "${DEPLOY}/kaptain-environment-cleanup-policy.yaml" ]
  [ "$(files_in "${DEPLOY}" | wc -l)" -eq 3 ]
}

@test "split-manifests copies an environment's whole tree to stages/deploy" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest app-one
  write_child_manifest run-env-a
  write_top_level_manifest kaptain-environment-cleanup-policy
  run split-manifests
  [ "$status" -eq 0 ]
  [ "$(files_in "${DEPLOY}")" = "$(files_in "${WORK}")" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${SEED}" ]
  grep -qF "Split complete, all to the stages" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests keeps nested paths in every dir it copies to" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  mkdir -p "${WORK}/${SELF_NAME}/nested" "${WORK}/app-one/nested/deeper" "${WORK}/run-env-a/nested"
  printf 'kind: ConfigMap\n' > "${WORK}/${SELF_NAME}/nested/own.yaml"
  printf 'kind: ConfigMap\n' > "${WORK}/app-one/nested/deeper/buried.yaml"
  printf 'kind: ConfigMap\n' > "${WORK}/run-env-a/nested/child.yaml"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SELF}/nested/own.yaml" ]
  [ -f "${DEPLOY}/app-one/nested/deeper/buried.yaml" ]
  [ -f "${SEED}/run-env-a/nested/child.yaml" ]
}

@test "split-manifests copies file contents unchanged" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  cmp "${WORK}/${SELF_NAME}/configmap.yaml" "${SELF}/configmap.yaml"
  cmp "${WORK}/app-one/configmap.yaml" "${DEPLOY}/app-one/configmap.yaml"
  cmp "${WORK}/run-env-a/configmap.yaml" "${SEED}/run-env-a/configmap.yaml"
}

# Every file lands in exactly one dir

@test "split-manifests places every file in exactly one dir" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  write_child_manifest run-env-b
  mark_child run-env-a
  write_top_level_manifest kaptain-environment-cleanup-policy
  run split-manifests
  [ "$status" -eq 0 ]
  local complete placed
  complete=$(files_in "${WORK}" | wc -l)
  placed=$(( $(files_in "${SELF}" | wc -l) + $(files_in "${SEED}" | wc -l) + $(files_in "${DEPLOY}" | wc -l) ))
  [ "${complete}" -eq 5 ]
  [ "${placed}" -eq "${complete}" ]
}

@test "split-manifests does not copy top-level dot files or dot dirs, which validation ignores too" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest app-one
  printf 'finder\n' > "${WORK}/.DS_Store"
  mkdir -p "${WORK}/.hidden"
  printf 'kind: ConfigMap\n' > "${WORK}/.hidden/unvalidated.yaml"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/app-one/configmap.yaml" ]
  [ ! -e "${DEPLOY}/.DS_Store" ]
  [ ! -e "${DEPLOY}/.hidden" ]
}

@test "split-manifests leaves an empty deploy stage for an empty tree" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -d "${DEPLOY}" ]
  [ -z "$(files_in "${DEPLOY}")" ]
}

# Namespaces go to their own stage, ahead of everything

write_namespace() {
  local file="$1"
  local name="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "${name}" > "${file}"
}

write_role_binding() {
  local file="$1"
  local namespace="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: binding\n  namespace: %s\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: admin\n' "${namespace}" > "${file}"
}

NAMESPACES_STAGE="work/stages/namespaces"
ROLE_BINDINGS="work/child-role-binding"

@test "split-manifests puts a seeded child's Namespace in the namespaces stage, not in its seed set" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child run-env-a
  write_namespace "${WORK}/run-env-a/namespace.yaml" run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/run-env-a/namespace.yaml" ]
  [ ! -e "${SEED}/run-env-a/namespace.yaml" ]
  [ -f "${SEED}/run-env-a/configmap.yaml" ]
}

@test "split-manifests puts an unmarked child's Namespace in the namespaces stage, not in the deploy stage" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-b
  write_namespace "${WORK}/run-env-b/namespace.yaml" run-env-b
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/run-env-b/namespace.yaml" ]
  [ ! -e "${DEPLOY}/run-env-b/namespace.yaml" ]
  [ -f "${DEPLOY}/run-env-b/configmap.yaml" ]
}

@test "split-manifests leaves every Namespace in the complete tree, to be validated there" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child run-env-a
  write_namespace "${WORK}/run-env-a/namespace.yaml" run-env-a
  write_namespace "${WORK}/shared-namespace.yaml" shared
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${WORK}/run-env-a/namespace.yaml" ]
  [ -f "${WORK}/shared-namespace.yaml" ]
}

@test "split-manifests knows a Namespace by its kind, whatever the file is called and however deep it is" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_namespace "${WORK}/app-one/nested/somewhere-to-live.yaml" app-one-space
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/app-one/nested/somewhere-to-live.yaml" ]
  [ ! -e "${DEPLOY}/app-one/nested/somewhere-to-live.yaml" ]
}

@test "split-manifests puts a Namespace at the top of the tree in the namespaces stage" {
  write_child_manifest "${SELF_NAME}"
  write_namespace "${WORK}/shared-namespace.yaml" shared
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/shared-namespace.yaml" ]
  [ ! -e "${DEPLOY}/shared-namespace.yaml" ]
}

@test "split-manifests puts an environment's Namespaces in the namespaces stage too" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest app-one
  write_namespace "${WORK}/app-one/namespace.yaml" app-one-space
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/app-one/namespace.yaml" ]
  [ ! -e "${DEPLOY}/app-one/namespace.yaml" ]
}

@test "split-manifests puts the run-platform's own Namespace in the namespaces stage too, not in self" {
  write_child_manifest "${SELF_NAME}"
  write_namespace "${WORK}/${SELF_NAME}/namespace.yaml" "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/${SELF_NAME}/namespace.yaml" ]
  [ ! -e "${SELF}/namespace.yaml" ]
  [ -f "${SELF}/configmap.yaml" ]
}

@test "split-manifests leaves the run-platform's own folder whole in the tree, for bootstrap" {
  write_child_manifest "${SELF_NAME}"
  write_namespace "${WORK}/${SELF_NAME}/namespace.yaml" "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${WORK}/${SELF_NAME}/namespace.yaml" ]
  [ -f "${WORK}/${SELF_NAME}/configmap.yaml" ]
}

@test "split-manifests leaves no namespaces stage behind when there are no Namespaces" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  run split-manifests
  [ "$status" -eq 0 ]
  [ ! -e "${TEST_RUN_BASE}/${NAMESPACES_STAGE}" ]
}

@test "split-manifests keeps each Namespace's path and file name in the namespaces stage" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  write_child_manifest run-env-b
  mark_child run-env-a
  write_namespace "${WORK}/run-env-a/namespace.yaml" run-env-a
  write_namespace "${WORK}/run-env-b/namespace.yaml" run-env-b
  write_namespace "${WORK}/run-env-b/nested/another.yaml" run-env-b-extra
  run split-manifests
  [ "$status" -eq 0 ]
  cmp "${WORK}/run-env-a/namespace.yaml" "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/run-env-a/namespace.yaml"
  cmp "${WORK}/run-env-b/namespace.yaml" "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/run-env-b/namespace.yaml"
  cmp "${WORK}/run-env-b/nested/another.yaml" "${TEST_RUN_BASE}/${NAMESPACES_STAGE}/run-env-b/nested/another.yaml"
  [ "$(files_in "${TEST_RUN_BASE}/${NAMESPACES_STAGE}" | wc -l)" -eq 3 ]
}

# CRDs go to their own stage too, ahead even of validation

write_crd() {
  local file="$1"
  local name="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: %s\n' "${name}" > "${file}"
}

CRDS_STAGE="work/stages/crds"

@test "split-manifests puts a CRD in the crds stage, not in the deploy stage, and leaves it in the tree" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_crd "${WORK}/app-one/widget-crd.yaml" widgets.example.com
  run split-manifests
  [ "$status" -eq 0 ]
  cmp "${WORK}/app-one/widget-crd.yaml" "${TEST_RUN_BASE}/${CRDS_STAGE}/app-one/widget-crd.yaml"
  [ ! -e "${DEPLOY}/app-one/widget-crd.yaml" ]
  [ -f "${DEPLOY}/app-one/configmap.yaml" ]
}

@test "split-manifests knows a CRD by its kind, whatever the file is called and however deep it is" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_crd "${WORK}/app-one/nested/definitions/things.yaml" things.example.com
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${CRDS_STAGE}/app-one/nested/definitions/things.yaml" ]
  [ ! -e "${DEPLOY}/app-one/nested/definitions/things.yaml" ]
}

@test "split-manifests puts a CRD at the top of the tree in the crds stage" {
  write_child_manifest "${SELF_NAME}"
  write_crd "${WORK}/widget-crd.yaml" widgets.example.com
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${CRDS_STAGE}/widget-crd.yaml" ]
  [ ! -e "${DEPLOY}/widget-crd.yaml" ]
}

@test "split-manifests puts an environment's CRDs in the crds stage too, for validation to refuse" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest app-one
  write_crd "${WORK}/app-one/widget-crd.yaml" widgets.example.com
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${CRDS_STAGE}/app-one/widget-crd.yaml" ]
  [ ! -e "${DEPLOY}/app-one/widget-crd.yaml" ]
}

@test "split-manifests leaves no crds stage behind when there are no CRDs" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  run split-manifests
  [ "$status" -eq 0 ]
  [ ! -e "${TEST_RUN_BASE}/${CRDS_STAGE}" ]
}

# A child's role binding in its own namespace leaves the tree

@test "split-manifests takes a seeded child's own-namespace role binding out of its set and out of the tree" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child run-env-a
  write_role_binding "${WORK}/run-env-a/rolebinding.yaml" run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${ROLE_BINDINGS}/run-env-a/rolebinding.yaml" ]
  [ ! -e "${SEED}/run-env-a/rolebinding.yaml" ]
  [ ! -e "${WORK}/run-env-a/rolebinding.yaml" ]
  [ -f "${SEED}/run-env-a/configmap.yaml" ]
  [ -f "${WORK}/run-env-a/configmap.yaml" ]
  grep -qF "Role binding in the run-env-a namespace" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests takes an unmarked child's own-namespace role binding out the same way" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-b
  write_role_binding "${WORK}/run-env-b/rolebinding.yaml" run-env-b
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${ROLE_BINDINGS}/run-env-b/rolebinding.yaml" ]
  [ ! -e "${DEPLOY}/run-env-b/rolebinding.yaml" ]
  [ ! -e "${WORK}/run-env-b/rolebinding.yaml" ]
}

@test "split-manifests knows that role binding by its namespace, whatever the file is called" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  write_role_binding "${WORK}/run-env-a/rbac/let-me-in.yaml" run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/${ROLE_BINDINGS}/run-env-a/rbac/let-me-in.yaml" ]
  [ ! -e "${WORK}/run-env-a/rbac/let-me-in.yaml" ]
}

@test "split-manifests only takes that role binding out of a run-* folder, a child environment's" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest vendor-thing
  write_role_binding "${WORK}/vendor-thing/rolebinding.yaml" vendor-thing
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/vendor-thing/rolebinding.yaml" ]
  [ -f "${WORK}/vendor-thing/rolebinding.yaml" ]
  [ ! -e "${TEST_RUN_BASE}/${ROLE_BINDINGS}" ]
}

@test "split-manifests leaves a child's role binding in the run-platform's namespace where it is" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child run-env-a
  write_role_binding "${WORK}/run-env-a/rolebinding.yaml" "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SEED}/run-env-a/rolebinding.yaml" ]
  [ -f "${WORK}/run-env-a/rolebinding.yaml" ]
  [ ! -e "${TEST_RUN_BASE}/${ROLE_BINDINGS}" ]
}

@test "split-manifests leaves the run-platform's own role bindings with its own set" {
  write_child_manifest "${SELF_NAME}"
  write_role_binding "${WORK}/${SELF_NAME}/rolebinding.yaml" "${SELF_NAME}"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${SELF}/rolebinding.yaml" ]
  [ -f "${WORK}/${SELF_NAME}/rolebinding.yaml" ]
  [ ! -e "${TEST_RUN_BASE}/${ROLE_BINDINGS}" ]
}

@test "split-manifests takes no role binding out on an environment deploy, where it is an ordinary manifest" {
  export ENVIRONMENT_TYPE="env"
  export ENVIRONMENT="run-env-a"
  write_child_manifest run-env-a
  write_role_binding "${WORK}/run-env-a/rolebinding.yaml" run-env-a
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/run-env-a/rolebinding.yaml" ]
  [ -f "${WORK}/run-env-a/rolebinding.yaml" ]
  [ ! -e "${TEST_RUN_BASE}/${ROLE_BINDINGS}" ]
}

@test "split-manifests fails on a manifest it cannot read" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  printf 'kind: [unclosed\n' > "${WORK}/app-one/broken.yaml"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not read the manifests in app-one to find its Namespaces"* ]]
}

# The split runs once per container

@test "split-manifests refuses to run a second time" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  run split-manifests
  [ "$status" -eq 0 ]
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Split has already run in this container, refusing to run it again: ${SELF} exists"* ]]
}

# Lineage data leaves the sets that are compared with the cluster

write_lineage_data() {
  local file="${WORK}/$1"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: lineage-data\ndata:\n  contract.yaml: |\n    version: 1.2.3\n' > "${file}"
}

@test "split-manifests moves the lineage data of the run-platform's own set to the deploy stage, keeping its path" {
  write_child_manifest "${SELF_NAME}"
  write_lineage_data "${SELF_NAME}/kaptain-app-lineage-data.yaml"
  write_lineage_data "${SELF_NAME}/nested/kaptain-app-lineage-data.yaml"
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/${SELF_NAME}/kaptain-app-lineage-data.yaml" ]
  [ -f "${DEPLOY}/${SELF_NAME}/nested/kaptain-app-lineage-data.yaml" ]
  [ ! -e "${SELF}/kaptain-app-lineage-data.yaml" ]
  [ ! -e "${SELF}/nested/kaptain-app-lineage-data.yaml" ]
  [ -f "${SELF}/configmap.yaml" ]
  [ -f "${WORK}/${SELF_NAME}/kaptain-app-lineage-data.yaml" ]
  grep -qF "Lineage data: ${SELF_NAME}/kaptain-app-lineage-data.yaml -> stages/deploy/${SELF_NAME}" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-manifests moves the lineage data of a seeded child to the deploy stage, keeping its path" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child run-env-a
  write_lineage_data run-env-a/kaptain-app-lineage-data.yaml
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/run-env-a/kaptain-app-lineage-data.yaml" ]
  [ ! -e "${SEED}/run-env-a/kaptain-app-lineage-data.yaml" ]
  [ -f "${SEED}/run-env-a/configmap.yaml" ]
  [ -f "${WORK}/run-env-a/kaptain-app-lineage-data.yaml" ]
}

@test "split-manifests moves a file of exactly that name, and no other" {
  write_child_manifest "${SELF_NAME}"
  write_lineage_data "${SELF_NAME}/kaptain-app-lineage-data.yaml"
  write_lineage_data "${SELF_NAME}/kaptain-environment-lineage-data.yaml"
  write_lineage_data "${SELF_NAME}/kaptain-app-lineage-data-extra.yaml"
  write_lineage_data "${SELF_NAME}/configmap-lineage-data.yaml"
  run split-manifests
  [ "$status" -eq 0 ]
  [ "$(files_in "${DEPLOY}/${SELF_NAME}")" = "./kaptain-app-lineage-data.yaml" ]
  [ -f "${SELF}/kaptain-environment-lineage-data.yaml" ]
  [ -f "${SELF}/kaptain-app-lineage-data-extra.yaml" ]
  [ -f "${SELF}/configmap-lineage-data.yaml" ]
}

@test "split-manifests leaves lineage data that is already bound for the deploy stage where it is" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_lineage_data app-one/kaptain-app-lineage-data.yaml
  run split-manifests
  [ "$status" -eq 0 ]
  [ -f "${DEPLOY}/app-one/kaptain-app-lineage-data.yaml" ]
  run grep -F "Lineage data:" "${TEST_RUN_BASE}/work/container.log"
  [ "$status" -eq 1 ]
}

@test "split-manifests refuses when the stages dir is already there, changing nothing" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  mkdir -p "${DEPLOY}/app-gone"
  printf 'kind: ConfigMap\n' > "${DEPLOY}/app-gone/stale.yaml"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Split has already run"* ]]
  [ -f "${DEPLOY}/app-gone/stale.yaml" ]
  [ ! -e "${DEPLOY}/app-one" ]
  [ -f "${WORK}/run-env-a/${MARKER_NAME}" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${SEED}" ]
}

@test "split-manifests refuses when the self dir is already there" {
  write_child_manifest "${SELF_NAME}"
  mkdir -p "${SELF}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Split has already run"* ]]
  [ ! -e "${STAGES}" ]
}

@test "split-manifests refuses when the seed dir is already there" {
  write_child_manifest "${SELF_NAME}"
  mkdir -p "${SEED}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Split has already run"* ]]
  [ ! -e "${STAGES}" ]
}

@test "split-manifests refuses when the child role binding dir is already there" {
  write_child_manifest "${SELF_NAME}"
  mkdir -p "${TEST_RUN_BASE}/work/child-role-binding"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Split has already run"* ]]
  [ ! -e "${STAGES}" ]
}

# Failures change nothing

@test "split-manifests fails a run-platform deploy without its own set, changing nothing" {
  write_child_manifest run-env-a
  mark_child run-env-a
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Run-platform's own set does not exist: ${SELF_NAME}"* ]]
  [ -f "${WORK}/run-env-a/${MARKER_NAME}" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${SEED}" ]
  [ ! -e "${STAGES}" ]
}

@test "split-manifests fails on a marker at the top of the tree, changing nothing" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest app-one
  printf 'kind: ConfigMap\n' > "${WORK}/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at the top of a child set: ${MARKER_NAME}"* ]]
  [ -f "${WORK}/${MARKER_NAME}" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${STAGES}" ]
}

@test "split-manifests fails on a marker nested below a child's top, changing nothing" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mkdir -p "${WORK}/run-env-a/nested"
  printf 'kind: ConfigMap\n' > "${WORK}/run-env-a/nested/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at the top of a child set: run-env-a/nested/${MARKER_NAME}"* ]]
  [ -f "${WORK}/run-env-a/nested/${MARKER_NAME}" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${STAGES}" ]
}

@test "split-manifests fails on a marker nested inside the run-platform's own set, changing nothing" {
  write_child_manifest "${SELF_NAME}"
  mkdir -p "${WORK}/${SELF_NAME}/nested"
  printf 'kind: ConfigMap\n' > "${WORK}/${SELF_NAME}/nested/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at the top of a child set: ${SELF_NAME}/nested/${MARKER_NAME}"* ]]
  [ -f "${WORK}/${SELF_NAME}/nested/${MARKER_NAME}" ]
  [ ! -e "${SELF}" ]
  [ ! -e "${STAGES}" ]
}

@test "split-manifests fails a well placed marker alongside a misplaced one without deleting either" {
  write_child_manifest "${SELF_NAME}"
  write_child_manifest run-env-a
  mark_child run-env-a
  printf 'kind: ConfigMap\n' > "${WORK}/${MARKER_NAME}"
  run split-manifests
  [ "$status" -ne 0 ]
  [ -f "${WORK}/run-env-a/${MARKER_NAME}" ]
  [ -f "${WORK}/${MARKER_NAME}" ]
}

@test "split-manifests fails an environment deploy that holds a marker, changing nothing" {
  export ENVIRONMENT_TYPE="env"
  write_child_manifest app-one
  write_child_manifest run-env-a
  mark_child run-env-a
  run split-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Seed-and-compare marker in a env deploy: run-env-a/${MARKER_NAME}"* ]]
  [[ "$output" == *"Only a run-platform (meta-env) deploy holds seed-and-compare sets"* ]]
  [ -f "${WORK}/run-env-a/${MARKER_NAME}" ]
  [ ! -e "${SEED}" ]
  [ ! -e "${STAGES}" ]
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
