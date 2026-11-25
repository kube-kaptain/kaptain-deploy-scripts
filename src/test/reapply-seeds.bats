#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for reapply-seeds-if-changed: a run-platform seeds each child marked
# seed-and-compare and afterwards leaves it alone unless something real changed.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  SEED="${TEST_RUN_BASE}/work/seed"
  LIVE="${TEST_RUN_BASE}/live"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
  NOTIFICATIONS="${TEST_RUN_BASE}/work/notifications.log"
  mkdir -p "${LIVE}"
}

teardown() {
  teardown_test_dirs
}

write_deployment() {
  local file="$1"
  local child="$2"
  local config="${3:-${child}-aaaaa}"
  local tag="${4:-1.0.4}"
  mkdir -p "$(dirname "${file}")"
  cat > "${file}" << YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${child}
  labels:
    kaptain.org/version: "${tag}"
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: ${child}
        kaptain.org/version: "${tag}"
    spec:
      containers:
        - name: default-app
          image: ghcr.io/org/run/${child}:${tag}
      volumes:
        - name: configmap
          configMap:
            name: ${config}
YAML
}

write_cronjob() {
  local file="$1"
  local child="$2"
  local config="${3:-${child}-aaaaa}"
  mkdir -p "$(dirname "${file}")"
  cat > "${file}" << YAML
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${child}
  annotations:
    keelson.pro/policy: patch
    keelson.pro/trigger-job-on-update: "true"
spec:
  suspend: true
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: default-app
              image: ghcr.io/org/run/${child}:1.0.4
          volumes:
            - name: configmap
              configMap:
                name: ${config}
YAML
}

write_configmap() {
  local file="$1"
  local name="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  chat: enabled\n' "${name}" > "${file}"
}

write_rolebinding() {
  local file="$1"
  local role="$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: binding\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: %s\n' "${role}" > "${file}"
}

# A deployment-mode child whose set the cluster already holds as written
seeded_child() {
  local child="$1"
  write_configmap "${SEED}/${child}/configmap.yaml" "${child}-aaaaa"
  write_deployment "${SEED}/${child}/deployment.yaml" "${child}"
  cluster_holds "${SEED}/${child}/configmap.yaml"
  cluster_holds "${SEED}/${child}/deployment.yaml"
}

# A deployment-mode child whose config changed since the cluster last saw it
changed_child() {
  local child="$1"
  write_configmap "${SEED}/${child}/configmap.yaml" "${child}-bbbbb"
  write_deployment "${SEED}/${child}/deployment.yaml" "${child}" "${child}-bbbbb"
  write_deployment "${LIVE}/${child}-deployment.yaml" "${child}" "${child}-aaaaa"
  cluster_holds "${SEED}/${child}/deployment.yaml" "${LIVE}/${child}-deployment.yaml"
}

applies_of() {
  grep -c -- "-R -f ${SEED}/$1" "${K_LOG}" || true
}

@test "reapply-seeds-if-changed refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  changed_child run-omg
  run reapply-seeds-if-changed
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy seeds child environments, this is env"* ]]
  [ ! -f "${K_LOG}" ]
}

# Nothing to do

@test "reapply-seeds-if-changed does nothing when there are no seed sets" {
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
}

@test "reapply-seeds-if-changed leaves alone a child whose manifests match its resources" {
  seeded_child run-omg
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 0 ]
  [ ! -f "${NOTIFICATIONS}" ]
  grep -qF "The run-omg manifests match its resources" "${TEST_RUN_BASE}/work/container.log"
}

@test "reapply-seeds-if-changed leaves alone a child that differs only by Kaptain's version labels" {
  write_deployment "${SEED}/run-omg/deployment.yaml" run-omg run-omg-aaaaa 1.0.4
  write_deployment "${LIVE}/deployment.yaml" run-omg run-omg-aaaaa 1.0.4
  yq --inplace '(.. | select(tag == "!!map" and has("kaptain.org/version")) | ."kaptain.org/version") = "1.0.3"' "${LIVE}/deployment.yaml"
  cluster_holds "${SEED}/run-omg/deployment.yaml" "${LIVE}/deployment.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 0 ]
}

@test "reapply-seeds-if-changed leaves alone a child the auto-updater has moved to a newer image tag" {
  write_deployment "${SEED}/run-omg/deployment.yaml" run-omg run-omg-aaaaa 1.0.4
  write_deployment "${LIVE}/deployment.yaml" run-omg run-omg-aaaaa 1.0.7
  cluster_holds "${SEED}/run-omg/deployment.yaml" "${LIVE}/deployment.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 0 ]
  [ ! -f "${NOTIFICATIONS}" ]
}

# Seeding and reapplying, deployment mode

@test "reapply-seeds-if-changed seeds a child that is not in the cluster yet" {
  write_configmap "${SEED}/run-omg/configmap.yaml" run-omg-aaaaa
  write_deployment "${SEED}/run-omg/deployment.yaml" run-omg
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  grep -qF -- "apply --server-side --field-manager=kaptain/meta-env/run-platform-test -R -f ${SEED}/run-omg" "${K_LOG}"
  grep -qF "INFO: The run-omg manifests differ from its resources (configmap.yaml missing, deployment.yaml missing). Reapplying in full - this will cause a restart of the run-omg environment control pod." "${NOTIFICATIONS}"
}

@test "reapply-seeds-if-changed reapplies a child whose config changed, in full" {
  changed_child run-omg
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  grep -qF "INFO: The run-omg manifests differ from its resources (configmap.yaml missing, deployment.yaml differs). Reapplying in full - this will cause a restart of the run-omg environment control pod." "${NOTIFICATIONS}"
  [ -f "${TEST_RUN_BASE}/work/audit/apply-seed-run-omg.log" ]
}

@test "reapply-seeds-if-changed keeps the newer live image tag when it reapplies for another reason" {
  write_configmap "${SEED}/run-omg/configmap.yaml" run-omg-bbbbb
  write_deployment "${SEED}/run-omg/deployment.yaml" run-omg run-omg-bbbbb 1.0.4
  write_deployment "${LIVE}/deployment.yaml" run-omg run-omg-aaaaa 1.0.7
  cluster_holds "${SEED}/run-omg/deployment.yaml" "${LIVE}/deployment.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  # What was applied is what the cluster now holds
  [ "$(yq '.spec.template.spec.containers[0].image' "$(cluster_path "${SEED}/run-omg/deployment.yaml")")" = "ghcr.io/org/run/run-omg:1.0.7" ]
}

@test "reapply-seeds-if-changed never starts a Job for a deployment-mode child" {
  changed_child run-omg
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
}

# Job mode

@test "reapply-seeds-if-changed starts a deploy Job for a job-mode child whose CronJob changed" {
  write_configmap "${SEED}/run-omg/configmap.yaml" run-omg-bbbbb
  write_cronjob "${SEED}/run-omg/cronjob.yaml" run-omg run-omg-bbbbb
  write_cronjob "${LIVE}/cronjob.yaml" run-omg run-omg-aaaaa
  cluster_holds "${SEED}/run-omg/cronjob.yaml" "${LIVE}/cronjob.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  grep -qF "INFO: The run-omg manifests differ from its resources (configmap.yaml missing, cronjob.yaml differs). Reapplying in full - a new deploy Job will be started for run-omg from its updated CronJob." "${NOTIFICATIONS}"
  grep -q -E -- "^create job --from=cronjob/run-omg run-omg-reapply-[0-9]+$" "${K_LOG}"
}

@test "reapply-seeds-if-changed starts no Job for a job-mode child seeded for the first time, leaving that to keelson" {
  write_configmap "${SEED}/run-omg/configmap.yaml" run-omg-aaaaa
  write_cronjob "${SEED}/run-omg/cronjob.yaml" run-omg
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "INFO: The run-omg manifests differ from its resources (configmap.yaml missing, cronjob.yaml missing). Reapplying in full - its CronJob is new to the cluster, so keelson will start its first deploy Job." "${NOTIFICATIONS}"
}

@test "reapply-seeds-if-changed starts the Job only after the apply" {
  write_cronjob "${SEED}/run-omg/cronjob.yaml" run-omg run-omg-bbbbb
  write_cronjob "${LIVE}/cronjob.yaml" run-omg run-omg-aaaaa
  cluster_holds "${SEED}/run-omg/cronjob.yaml" "${LIVE}/cronjob.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  local applied started
  applied=$(grep -n -- "-R -f ${SEED}/run-omg" "${K_LOG}" | cut -d: -f1)
  started=$(grep -n -- "^create job" "${K_LOG}" | cut -d: -f1)
  [ "${applied}" -lt "${started}" ]
}

@test "reapply-seeds-if-changed starts no Job when a job-mode child's CronJob did not change" {
  write_cronjob "${SEED}/run-omg/cronjob.yaml" run-omg
  write_rolebinding "${SEED}/run-omg/rolebinding.yaml" admin
  write_rolebinding "${LIVE}/rolebinding.yaml" view
  cluster_holds "${SEED}/run-omg/cronjob.yaml"
  cluster_holds "${SEED}/run-omg/rolebinding.yaml" "${LIVE}/rolebinding.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "Its CronJob did not change, so no new deploy Job was needed after all" "${NOTIFICATIONS}"
}

# Which CronJob makes a child job-mode: only its deployer, named for the child,
# suspended, with keelson annotations. A changed CronJob that is not that is
# reapplied like any other resource and never has a Job started from it.

# A child in deployment mode whose set also holds a CronJob the cluster has an
# older form of. The yq expression turns that CronJob into the kind under test.
child_with_changed_cronjob() {
  local reshape="$1"
  seeded_child run-omg
  write_cronjob "${SEED}/run-omg/cronjob.yaml" run-omg run-omg-bbbbb
  write_cronjob "${LIVE}/cronjob.yaml" run-omg run-omg-aaaaa
  yq --inplace "${reshape}" "${SEED}/run-omg/cronjob.yaml"
  yq --inplace "${reshape}" "${LIVE}/cronjob.yaml"
  cluster_holds "${SEED}/run-omg/cronjob.yaml" "${LIVE}/cronjob.yaml"
}

@test "reapply-seeds-if-changed does not treat a CronJob with another name as the child's deployer" {
  child_with_changed_cronjob '.metadata.name = "nightly-report"'
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "this will cause a restart of the run-omg environment control pod." "${NOTIFICATIONS}"
}

@test "reapply-seeds-if-changed does not treat a CronJob that is not suspended as the child's deployer" {
  child_with_changed_cronjob '.spec.suspend = false'
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "reapply-seeds-if-changed does not treat a CronJob without keelson annotations as the child's deployer" {
  child_with_changed_cronjob 'del(.metadata.annotations)'
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-omg)" -eq 1 ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "reapply-seeds-if-changed starts a Job from the deployer CronJob only, when the set holds others too" {
  write_cronjob "${SEED}/run-omg/cronjob.yaml" run-omg run-omg-bbbbb
  write_cronjob "${LIVE}/cronjob.yaml" run-omg run-omg-aaaaa
  cluster_holds "${SEED}/run-omg/cronjob.yaml" "${LIVE}/cronjob.yaml"
  write_cronjob "${SEED}/run-omg/cronjob-nightly-report.yaml" run-omg run-omg-bbbbb
  yq --inplace '.metadata.name = "nightly-report"' "${SEED}/run-omg/cronjob-nightly-report.yaml"
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^create job" "${K_LOG}")" -eq 1 ]
  grep -q -E -- "^create job --from=cronjob/run-omg run-omg-reapply-[0-9]+$" "${K_LOG}"
}

# One child at a time

@test "reapply-seeds-if-changed reapplies only the children that differ" {
  seeded_child run-alpha
  changed_child run-bravo
  seeded_child run-charlie
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  [ "$(applies_of run-alpha)" -eq 0 ]
  [ "$(applies_of run-bravo)" -eq 1 ]
  [ "$(applies_of run-charlie)" -eq 0 ]
}

@test "reapply-seeds-if-changed checks and applies one child before it looks at the next" {
  changed_child run-alpha
  changed_child run-bravo
  run reapply-seeds-if-changed
  [ "$status" -eq 0 ]
  local alpha_applied bravo_first_seen
  alpha_applied=$(grep -n -- "-R -f ${SEED}/run-alpha" "${K_LOG}" | cut -d: -f1)
  bravo_first_seen=$(grep -n -- "${SEED}/run-bravo" "${K_LOG}" | head -n 1 | cut -d: -f1)
  [ "${alpha_applied}" -lt "${bravo_first_seen}" ]
}

@test "reapply-seeds-if-changed stops at a child whose apply fails, leaving the rest untouched" {
  changed_child run-alpha
  changed_child run-bravo
  cluster_fails apply
  run reapply-seeds-if-changed
  [ "$status" -ne 0 ]
  [[ "$output" == *"Reapplying the run-alpha manifests failed"* ]]
  run grep -- "${SEED}/run-bravo" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "reapply-seeds-if-changed stops when a compare cannot be done, applying nothing" {
  seeded_child run-alpha
  cluster_fails dry-run
  run reapply-seeds-if-changed
  [ "$status" -ne 0 ]
  run grep -- "-R -f" "${K_LOG}"
  [ "$status" -eq 1 ]
}
