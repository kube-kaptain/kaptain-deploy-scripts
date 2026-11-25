#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for reapply-self-if-changed: a run-platform compares its own set with
# the cluster before anything else, and reapplies it when it differs.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  export DEPLOY_MODE="deployment"
  export HOSTNAME="run-platform-test-5d4f8c7b9-x2x4z"
  SELF="${TEST_RUN_BASE}/work/self"
  LIVE="${TEST_RUN_BASE}/live"
  OUTCOME="${TEST_RUN_BASE}/work/self-outcome"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
  NOTIFICATIONS="${TEST_RUN_BASE}/work/notifications.log"
  mkdir -p "${SELF}" "${LIVE}"
}

teardown() {
  teardown_test_dirs
}

# The run-platform's deployer. The ConfigMap it mounts is what changes when its
# config does.
write_deployment() {
  local file="$1"
  local config="${2:-run-platform-test-aaaaa}"
  cat > "${file}" << YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: run-platform-test
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: default-app
          image: ghcr.io/org/run/run-platform-test:1.0.4
      volumes:
        - name: configmap
          configMap:
            name: ${config}
YAML
}

write_cronjob() {
  local file="$1"
  local config="${2:-run-platform-test-aaaaa}"
  cat > "${file}" << YAML
apiVersion: batch/v1
kind: CronJob
metadata:
  name: run-platform-test
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
              image: ghcr.io/org/run/run-platform-test:1.0.4
          volumes:
            - name: configmap
              configMap:
                name: ${config}
YAML
}

write_configmap() {
  local file="$1"
  local name="${2:-run-platform-test-aaaaa}"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  chat: enabled\n' "${name}" > "${file}"
}

write_rolebinding() {
  local file="$1"
  local role="${2:-admin}"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: run-platform-test\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: %s\n' "${role}" > "${file}"
}

# The cluster holds the previous version: the old ConfigMap, mounted by the
# old Deployment or CronJob. Our set holds the new one of each.
cluster_holds_previous_config() {
  local workload="$1"
  write_configmap "${SELF}/configmap.yaml" run-platform-test-bbbbb
  "write_${workload}" "${SELF}/${workload}.yaml" run-platform-test-bbbbb
  "write_${workload}" "${LIVE}/${workload}.yaml" run-platform-test-aaaaa
  cluster_holds "${SELF}/${workload}.yaml" "${LIVE}/${workload}.yaml"
}

@test "reapply-self-if-changed refuses to run on anything but a run-platform" {
  export ENVIRONMENT_TYPE="env"
  cluster_holds_previous_config deployment
  run reapply-self-if-changed
  [ "$status" -ne 0 ]
  [[ "$output" == *"Only a run-platform (meta-env) deploy reapplies its own manifests, this is env"* ]]
  [ ! -f "${K_LOG}" ]
  [ ! -f "${OUTCOME}" ]
}

# Nothing to do

@test "reapply-self-if-changed carries on when our manifests match our resources" {
  write_configmap "${SELF}/configmap.yaml"
  write_deployment "${SELF}/deployment.yaml"
  cluster_holds "${SELF}/configmap.yaml"
  cluster_holds "${SELF}/deployment.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
  grep -qF "Our manifests match our resources" "${TEST_RUN_BASE}/work/container.log"
}

@test "reapply-self-if-changed applies nothing and says nothing in chat when nothing differs" {
  write_configmap "${SELF}/configmap.yaml"
  write_deployment "${SELF}/deployment.yaml"
  cluster_holds "${SELF}/configmap.yaml"
  cluster_holds "${SELF}/deployment.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  run grep -- "-R -f" "${K_LOG}"
  [ "$status" -eq 1 ]
  [ ! -f "${NOTIFICATIONS}" ]
}

# Reapplying

@test "reapply-self-if-changed says what differs and that a restart is coming, before applying" {
  cluster_holds_previous_config deployment
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  grep -qF "INFO: Our manifests differ from our resources (configmap.yaml missing, deployment.yaml differs). Reapplying, which will cause a restart. This check should pass after that." "${NOTIFICATIONS}"
}

@test "reapply-self-if-changed applies our own set in full under our field manager, without forcing" {
  cluster_holds_previous_config deployment
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  grep -qF -- "apply --server-side --field-manager=kaptain/meta-env/run-platform-test -R -f ${SELF}" "${K_LOG}"
  run grep -- "--force-conflicts" "${K_LOG}"
  [ "$status" -eq 1 ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply-self.log" ]
}

@test "reapply-self-if-changed applies our own set exactly as written" {
  cluster_holds_previous_config deployment
  local written
  written=$(<"${SELF}/deployment.yaml")
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${SELF}/deployment.yaml")" = "${written}" ]
}

@test "reapply-self-if-changed stands down in deployment mode when the apply changed our pod template" {
  cluster_holds_previous_config deployment
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "stand-down" ]
}

@test "reapply-self-if-changed carries on when the apply changed nothing that runs this pod" {
  write_deployment "${SELF}/deployment.yaml"
  write_rolebinding "${SELF}/rolebinding.yaml" admin
  write_rolebinding "${LIVE}/rolebinding.yaml" view
  cluster_holds "${SELF}/deployment.yaml"
  cluster_holds "${SELF}/rolebinding.yaml" "${LIVE}/rolebinding.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
  grep -qF -- "-R -f ${SELF}" "${K_LOG}"
  grep -qF "Nothing that runs this pod changed, so no restart is coming after all" "${NOTIFICATIONS}"
}

@test "reapply-self-if-changed in deployment mode is not moved by a CronJob changing" {
  write_deployment "${SELF}/deployment.yaml"
  write_cronjob "${SELF}/cronjob.yaml" run-platform-test-bbbbb
  write_cronjob "${LIVE}/cronjob.yaml" run-platform-test-aaaaa
  cluster_holds "${SELF}/deployment.yaml"
  cluster_holds "${SELF}/cronjob.yaml" "${LIVE}/cronjob.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
}

# Job mode

@test "reapply-self-if-changed in job mode starts a new Job from the updated CronJob and hands over" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  cluster_holds_previous_config cronjob
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "handed-over" ]
  grep -q -E -- "^create job --from=cronjob/run-platform-test run-platform-test-reapply-[0-9]+$" "${K_LOG}"
  grep -q -E "INFO: Starting Job run-platform-test-reapply-[0-9]+ from our updated CronJob to carry on with the deploy. This one stops here." "${NOTIFICATIONS}"
}

@test "reapply-self-if-changed in job mode says it is starting the Job before it creates it" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  cluster_holds_previous_config cronjob
  # The message is already out when the create is refused
  cluster_fails create
  run reapply-self-if-changed
  [ "$status" -ne 0 ]
  grep -q -E "INFO: Starting Job run-platform-test-reapply-[0-9]+ from our updated CronJob" "${NOTIFICATIONS}"
  [[ "$output" == *"Could not start Job run-platform-test-reapply-"* ]]
  [ ! -f "${OUTCOME}" ]
}

@test "reapply-self-if-changed in job mode does not wait for or look at the Job it started" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  cluster_holds_previous_config cronjob
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  # Creating the Job is the last thing it asks of the cluster
  [[ "$(tail -n 1 "${K_LOG}")" == "create job --from=cronjob/run-platform-test run-platform-test-reapply-"* ]]
}

@test "reapply-self-if-changed in job mode is not moved by another CronJob in its set changing" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  write_cronjob "${SELF}/cronjob.yaml"
  cluster_holds "${SELF}/cronjob.yaml"
  write_cronjob "${SELF}/cronjob-nightly-report.yaml" run-platform-test-bbbbb
  write_cronjob "${LIVE}/cronjob-nightly-report.yaml" run-platform-test-aaaaa
  yq --inplace '.metadata.name = "nightly-report"' "${SELF}/cronjob-nightly-report.yaml"
  yq --inplace '.metadata.name = "nightly-report"' "${LIVE}/cronjob-nightly-report.yaml"
  cluster_holds "${SELF}/cronjob-nightly-report.yaml" "${LIVE}/cronjob-nightly-report.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "reapply-self-if-changed in deployment mode is not moved by another Deployment in its set changing" {
  write_deployment "${SELF}/deployment.yaml"
  cluster_holds "${SELF}/deployment.yaml"
  write_deployment "${SELF}/deployment-helper.yaml" run-platform-test-bbbbb
  write_deployment "${LIVE}/deployment-helper.yaml" run-platform-test-aaaaa
  yq --inplace '.metadata.name = "helper"' "${SELF}/deployment-helper.yaml"
  yq --inplace '.metadata.name = "helper"' "${LIVE}/deployment-helper.yaml"
  cluster_holds "${SELF}/deployment-helper.yaml" "${LIVE}/deployment-helper.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
}

@test "reapply-self-if-changed in job mode starts the Job only after the apply" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  cluster_holds_previous_config cronjob
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  local applied started
  applied=$(grep -n -- "-R -f ${SELF}" "${K_LOG}" | cut -d: -f1)
  started=$(grep -n -- "^create job" "${K_LOG}" | cut -d: -f1)
  [ "${applied}" -lt "${started}" ]
}

@test "reapply-self-if-changed in job mode carries on when the CronJob did not change" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  write_cronjob "${SELF}/cronjob.yaml"
  write_rolebinding "${SELF}/rolebinding.yaml" admin
  write_rolebinding "${LIVE}/rolebinding.yaml" view
  cluster_holds "${SELF}/cronjob.yaml"
  cluster_holds "${SELF}/rolebinding.yaml" "${LIVE}/rolebinding.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "reapply-self-if-changed in job mode is not moved by the utility Deployment changing" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-29384756-abcde"
  write_cronjob "${SELF}/cronjob.yaml"
  write_deployment "${SELF}/deployment.yaml" run-platform-test-bbbbb
  write_deployment "${LIVE}/deployment.yaml" run-platform-test-aaaaa
  cluster_holds "${SELF}/cronjob.yaml"
  cluster_holds "${SELF}/deployment.yaml" "${LIVE}/deployment.yaml"
  run reapply-self-if-changed
  [ "$status" -eq 0 ]
  [ "$(<"${OUTCOME}")" = "continue" ]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "reapply-self-if-changed in a Job a reapply started does not start another" {
  export DEPLOY_MODE="job"
  export HOSTNAME="run-platform-test-reapply-1790000000-abcde"
  cluster_holds_previous_config cronjob
  run reapply-self-if-changed
  [ "$status" -ne 0 ]
  [[ "$output" == *"started by a reapply of our own manifests and has just had to reapply them again - not starting another"* ]]
  run grep -- "^create job" "${K_LOG}"
  [ "$status" -eq 1 ]
  [ ! -f "${OUTCOME}" ]
}

# Failures

@test "reapply-self-if-changed fails when the apply fails, pointing at apply-force" {
  cluster_holds_previous_config deployment
  cluster_fails apply
  run reapply-self-if-changed
  [ "$status" -ne 0 ]
  [[ "$output" == *"Reapplying our own manifests failed"* ]]
  [[ "$output" == *"apply-force ${SELF} takes them back"* ]]
  [ ! -f "${OUTCOME}" ]
}

@test "reapply-self-if-changed fails when the compare cannot be done, applying nothing" {
  write_configmap "${SELF}/configmap.yaml"
  cluster_fails get
  run reapply-self-if-changed
  [ "$status" -ne 0 ]
  run grep -- "-R -f" "${K_LOG}"
  [ "$status" -eq 1 ]
  [ ! -f "${OUTCOME}" ]
}
