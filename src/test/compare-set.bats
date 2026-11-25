#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for compare-set: does a set of manifests need applying?
#
# The mock k keeps a fake cluster. cluster_holds puts the live form of a
# manifest in it, and a dry-run answers with the manifest as written unless
# cluster_would_make says otherwise.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  SET="${TEST_RUN_BASE}/work/seed/run-omg"
  COMPARE="${TEST_RUN_BASE}/work/audit/compare/seed/run-omg"
  DIFFERENCES="${COMPARE}/differences"
  LIVE="${TEST_RUN_BASE}/live"
  mkdir -p "${SET}" "${LIVE}"
}

teardown() {
  teardown_test_dirs
}

# A deployer Deployment as a build writes it. The arguments vary the parts a
# compare has to tell apart.
write_deployment() {
  local file="$1"
  local image="${2:-ghcr.io/org/run/run-omg:1.0.4}"
  local version="${3:-1.0.4}"
  local config="${4:-run-omg-aaaaa}"
  mkdir -p "$(dirname "${file}")"
  cat > "${file}" << YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: run-omg
  namespace: run-platform-test
  labels:
    app: run-omg
    app.kubernetes.io/version: "${version}"
    kaptain.org/version: "${version}"
  annotations:
    kaptain.org/build-timestamp: "built-for-${version}"
    keelson.pro/policy: patch
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: run-omg
        kaptain.org/version: "${version}"
      annotations:
        kaptain.org/build-timestamp: "built-for-${version}"
    spec:
      containers:
        - name: default-app
          image: ${image}
      volumes:
        - name: configmap
          configMap:
            name: ${config}
YAML
}

write_configmap() {
  local file="$1"
  local name="${2:-run-omg-aaaaa}"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: run-platform-test\ndata:\n  chat: enabled\n' "${name}" > "${file}"
}

# Usage and plumbing

@test "compare-set needs exactly one argument" {
  run compare-set
  [ "$status" -eq 42 ]
  run compare-set one two
  [ "$status" -eq 42 ]
}

@test "compare-set fails when the set does not exist" {
  run compare-set "${TEST_RUN_BASE}/work/seed/run-gone"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Set to compare does not exist"* ]]
}

@test "compare-set writes its answer under the set's name in the audit dir" {
  mkdir -p "${TEST_RUN_BASE}/work/self"
  write_configmap "${TEST_RUN_BASE}/work/self/configmap.yaml"
  run compare-set "${TEST_RUN_BASE}/work/self"
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/audit/compare/self/differences" ]
}

@test "compare-set accepts the set dir with a trailing slash" {
  write_configmap "${SET}/configmap.yaml"
  run compare-set "${SET}/"
  [ "$status" -eq 0 ]
  [ -f "${DIFFERENCES}" ]
}

# Missing

@test "compare-set reports every file as missing against an empty cluster" {
  write_configmap "${SET}/configmap.yaml"
  write_deployment "${SET}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "configmap.yaml missing
deployment.yaml missing" ]
}

@test "compare-set reports only the file that is missing" {
  write_configmap "${SET}/configmap.yaml"
  write_deployment "${SET}/deployment.yaml"
  cluster_holds "${SET}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "configmap.yaml missing" ]
}

@test "compare-set names a nested file by its path within the set" {
  write_configmap "${SET}/nested/deeper/configmap.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "nested/deeper/configmap.yaml missing" ]
}

# The same

@test "compare-set finds no differences when the cluster holds the set as written" {
  write_configmap "${SET}/configmap.yaml"
  write_deployment "${SET}/deployment.yaml"
  cluster_holds "${SET}/configmap.yaml"
  cluster_holds "${SET}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ -f "${DIFFERENCES}" ]
  [ ! -s "${DIFFERENCES}" ]
}

@test "compare-set ignores Kaptain's own labels and annotations, on the object and its pod template" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 1.0.9
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 1.0.4
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ ! -s "${DIFFERENCES}" ]
}

@test "compare-set ignores Kaptain's own labels and annotations in a CronJob's job template" {
  cat > "${SET}/cronjob.yaml" << 'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: run-omg
spec:
  suspend: true
  jobTemplate:
    metadata:
      labels:
        kaptain.org/version: "1.0.9"
    spec:
      template:
        metadata:
          annotations:
            kaptain.org/build-timestamp: new
        spec:
          containers:
            - name: default-app
              image: ghcr.io/org/run/run-omg:1.0.9
YAML
  sed -e 's/"1.0.9"/"1.0.4"/' -e 's/build-timestamp: new/build-timestamp: old/' -e 's/run-omg:1.0.9/run-omg:1.0.4/' \
    "${SET}/cronjob.yaml" > "${LIVE}/cronjob.yaml"
  cluster_holds "${SET}/cronjob.yaml" "${LIVE}/cronjob.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ ! -s "${DIFFERENCES}" ]
}

@test "compare-set ignores a different image tag" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ ! -s "${DIFFERENCES}" ]
}

@test "compare-set ignores a digest in place of a tag" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg@sha256:0123abcd
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ ! -s "${DIFFERENCES}" ]
}

@test "compare-set ignores status and the server's bookkeeping on the live object" {
  write_configmap "${SET}/configmap.yaml"
  cp "${SET}/configmap.yaml" "${LIVE}/configmap.yaml"
  yq --inplace '
    .metadata.uid = "0000-1111" |
    .metadata.resourceVersion = "123456" |
    .metadata.generation = 7 |
    .metadata.creationTimestamp = "2026-01-01T00:00:00Z" |
    .metadata.managedFields = [{"manager": "kaptain/meta-env/run-platform-test"}] |
    .status = {"observed": true}
  ' "${LIVE}/configmap.yaml"
  cluster_holds "${SET}/configmap.yaml" "${LIVE}/configmap.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ ! -s "${DIFFERENCES}" ]
}

@test "compare-set does not see what another manager put on the object, since an apply would leave it there" {
  write_deployment "${SET}/deployment.yaml"
  cp "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  yq --inplace '
    .metadata.annotations."deployment.kubernetes.io/revision" = "7" |
    .metadata.labels."mesh.example.com/inject" = "true" |
    .spec.progressDeadlineSeconds = 600
  ' "${LIVE}/deployment.yaml"
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  # The dry-run answers with the live object's extras still in place
  cluster_would_make "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ ! -s "${DIFFERENCES}" ]
}

# Differs

@test "compare-set reports a changed field" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 1.0.4 run-omg-bbbbb
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 1.0.4 run-omg-aaaaa
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set reports a field an apply would remove" {
  write_deployment "${SET}/deployment.yaml"
  cp "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  yq --inplace '.spec.template.spec.containers[0].env = [{"name": "GONE", "value": "soon"}]' "${LIVE}/deployment.yaml"
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set reports a different registry" {
  write_deployment "${SET}/deployment.yaml" registry.example.com/org/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set reports a different image namespace" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/other/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set reports a different image name" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg-two:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set does not take a registry port for a tag" {
  write_deployment "${SET}/deployment.yaml" registry.example.com:5000/run-omg
  write_deployment "${LIVE}/deployment.yaml" registry.example.com:6000/run-omg
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set counts a keelson annotation, which changes behaviour" {
  write_deployment "${SET}/deployment.yaml"
  cp "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  yq --inplace '.metadata.annotations."keelson.pro/policy" = "minor"' "${LIVE}/deployment.yaml"
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set counts any label that is not Kaptain's own" {
  write_deployment "${SET}/deployment.yaml"
  yq --inplace '.spec.template.metadata.labels."team.example.com/owner" = "blue"' "${SET}/deployment.yaml"
  cp "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  yq --inplace '.spec.template.metadata.labels."team.example.com/owner" = "green"' "${LIVE}/deployment.yaml"
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "deployment.yaml differs" ]
}

@test "compare-set counts a Namespace's additional labels" {
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: run-omg\n  labels:\n    kaptain.org/version: "1.0.9"\n    pod-security.kubernetes.io/enforce: restricted\n' > "${SET}/namespace.yaml"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: run-omg\n  labels:\n    kaptain.org/version: "1.0.4"\n    pod-security.kubernetes.io/enforce: baseline\n' > "${LIVE}/namespace.yaml"
  cluster_holds "${SET}/namespace.yaml" "${LIVE}/namespace.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "namespace.yaml differs" ]
}

@test "compare-set does not treat an image key in a ConfigMap's data as a container image" {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\ndata:\n  image: "ghcr.io/org/thing:2"\n' > "${SET}/configmap.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\ndata:\n  image: "ghcr.io/org/thing:1"\n' > "${LIVE}/configmap.yaml"
  cluster_holds "${SET}/configmap.yaml" "${LIVE}/configmap.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "configmap.yaml differs" ]
}

# What is kept for inspection

@test "compare-set keeps both stripped documents for a file that differs" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 1.0.4 run-omg-bbbbb
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 1.0.4 run-omg-aaaaa
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  grep -q "run-omg-aaaaa" "${COMPARE}/deployment.live.yaml"
  grep -q "run-omg-bbbbb" "${COMPARE}/deployment.wanted.yaml"
  run grep "kaptain.org/" "${COMPARE}/deployment.live.yaml"
  [ "$status" -eq 1 ]
}

@test "compare-set keeps nothing of a Secret but the verdict" {
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: run-omg-ccccc\nstringData:\n  environmentPassphrase: new-passphrase\n' > "${SET}/secret.yaml"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: run-omg-ccccc\nstringData:\n  environmentPassphrase: old-passphrase\n' > "${LIVE}/secret.yaml"
  cluster_holds "${SET}/secret.yaml" "${LIVE}/secret.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  [ "$(<"${DIFFERENCES}")" = "secret.yaml differs" ]
  run grep -r "passphrase" "${COMPARE}"
  [ "$status" -eq 1 ]
}

# A compare that cannot be done fails

@test "compare-set fails when the live object cannot be read for a reason other than not being there" {
  write_configmap "${SET}/configmap.yaml"
  cluster_fails get
  run compare-set "${SET}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not read the live object for seed/run-omg/configmap.yaml"* ]]
}

@test "compare-set says who owns the field and points at apply-force when the dry-run is refused as a conflict" {
  write_configmap "${SET}/configmap.yaml"
  cluster_holds "${SET}/configmap.yaml"
  cluster_fails dry-run
  run compare-set "${SET}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"The cluster will not let seed/run-omg/configmap.yaml be applied: something else now owns a field it sets."* ]]
  [[ "$output" == *"conflict with \"someone-else\" using apps/v1: .spec.replicas"* ]]
  [[ "$output" == *"take the field back by hand: apply-force ${SET}/configmap.yaml"* ]]
  grep -q "conflict" "${COMPARE}/configmap.err"
}

@test "compare-set leaves kubectl's own advice about forcing out of the conflict message" {
  write_configmap "${SET}/configmap.yaml"
  cluster_holds "${SET}/configmap.yaml"
  cluster_fails dry-run
  run compare-set "${SET}"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Please review the fields above"* ]]
  [[ "$output" != *"--force-conflicts"* ]]
}

@test "compare-set fails when the cluster refuses the dry-run for any other reason" {
  write_configmap "${SET}/configmap.yaml"
  cluster_holds "${SET}/configmap.yaml"
  cluster_fails dry-run-invalid
  run compare-set "${SET}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not ask the cluster what seed/run-omg/configmap.yaml would become"* ]]
  [[ "$output" != *"apply-force"* ]]
  grep -q "immutable" "${COMPARE}/configmap.err"
}

@test "compare-set asks under the environment's field manager and changes nothing" {
  write_configmap "${SET}/configmap.yaml"
  cluster_holds "${SET}/configmap.yaml"
  run compare-set "${SET}"
  [ "$status" -eq 0 ]
  grep -q -- "apply --dry-run=server --server-side --field-manager=kaptain/meta-env/run-platform-test -f ${SET}/configmap.yaml -o yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  run grep -v -E -- "--dry-run=server|^get " "${TEST_RUN_BASE}/work/k-commands.log"
  [ "$status" -eq 1 ]
}
