#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for record-baseline: the workloads a deploy declares, the restart
# counts of their live pods and the Jobs the cluster does not have yet, all
# written down before anything that runs is applied.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-test-env"
  export ENVIRONMENT_TYPE="env"
  MANIFESTS="${TEST_RUN_BASE}/work/manifests"
  BASELINE="${TEST_RUN_BASE}/work/baseline"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
  mkdir -p "${MANIFESTS}"
}

teardown() {
  teardown_test_dirs
}

# A manifest with a pod spec in it: its kind, its name, where it sits in the
# tree, and the one label its pod template carries (key=value, or none). The
# label is app=<name> unless a test says otherwise. Any kind this does not know
# is written in the shape of a Deployment, as a custom kind would be.
workload() {
  local kind="$1"
  local name="$2"
  local file="${MANIFESTS}/$3"
  local label="${4:-app=${name}}"
  mkdir -p "$(dirname "${file}")"

  local labels="{}"
  if [[ "${label}" != "none" ]]; then
    labels="{\"${label%%=*}\": \"${label#*=}\"}"
  fi

  case "${kind}" in
    Pod)
      printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  labels: %s\nspec:\n  containers:\n    - name: main\n      image: example.org/thing:1.0.0\n' \
        "${name}" "${labels}" > "${file}"
      ;;
    CronJob)
      printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: %s\nspec:\n  schedule: "0 3 * * *"\n  jobTemplate:\n    spec:\n      template:\n        metadata:\n          labels: %s\n        spec:\n          containers:\n            - name: main\n              image: example.org/thing:1.0.0\n' \
        "${name}" "${labels}" > "${file}"
      ;;
    *)
      printf 'apiVersion: example.org/v1\nkind: %s\nmetadata:\n  name: %s\nspec:\n  template:\n    metadata:\n      labels: %s\n    spec:\n      containers:\n        - name: main\n          image: example.org/thing:1.0.0\n' \
        "${kind}" "${name}" "${labels}" > "${file}"
      ;;
  esac
}

# Something that is not a workload
config() {
  local name="$1"
  local file="${MANIFESTS}/$2"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  key: value\n' "${name}" > "${file}"
}

# The workloads declared

@test "record-baseline lists every manifest holding a pod spec, sorted, with where it is in the tree" {
  workload StatefulSet db db/statefulset.yaml
  workload Deployment api api/deployment.yaml
  workload DaemonSet agent agent/daemonset.yaml
  workload Job migrate api/job-migrate.yaml
  workload CronJob nightly reports/cronjob-nightly.yaml
  workload Pod probe pod-probe.yaml
  config api-config api/configmap.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/all")" = "CronJob|nightly|reports/cronjob-nightly.yaml
DaemonSet|agent|agent/daemonset.yaml
Deployment|api|api/deployment.yaml
Job|migrate|api/job-migrate.yaml
Pod|probe|pod-probe.yaml
StatefulSet|db|db/statefulset.yaml" ]
}

@test "record-baseline finds a workload by its pod spec, not its kind, so a custom kind counts" {
  workload Rollout api api/rollout.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/all")" = "Rollout|api|api/rollout.yaml" ]
  [ "$(<"${BASELINE}/long-running")" = "Rollout|api|api/rollout.yaml" ]
}

@test "record-baseline does not take a CRD whose schema describes containers for a workload" {
  workload Deployment api api/deployment.yaml
  cat > "${MANIFESTS}/customresourcedefinition-widget.yaml" << 'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.org
spec:
  group: example.org
  names:
    kind: Widget
  versions:
    - name: v1
      schema:
        openAPIV3Schema:
          properties:
            spec:
              properties:
                template:
                  properties:
                    spec:
                      properties:
                        containers:
                          type: array
                      required:
                        - containers
EOF
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/all")" = "Deployment|api|api/deployment.yaml" ]
}

@test "record-baseline does not take a ConfigMap carrying a workload's YAML in its data for one" {
  workload Deployment api api/deployment.yaml
  cat > "${MANIFESTS}/configmap-templates.yaml" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: templates
data:
  deployment.yaml: |
    kind: Deployment
    metadata:
      name: templated
    spec:
      template:
        spec:
          containers:
            - name: main
              image: example.org/thing:1.0.0
EOF
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/all")" = "Deployment|api|api/deployment.yaml" ]
}

@test "record-baseline drops CronJobs from what is checked, and Jobs as well from what is long-running" {
  workload Deployment api api/deployment.yaml
  workload Job migrate api/job-migrate.yaml
  workload CronJob nightly reports/cronjob-nightly.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/to-check")" = "Deployment|api|api/deployment.yaml
Job|migrate|api/job-migrate.yaml" ]
  [ "$(<"${BASELINE}/long-running")" = "Deployment|api|api/deployment.yaml" ]
}

@test "record-baseline writes all six files even when nothing declared is a workload" {
  config api-config api/configmap.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  for file in all to-check long-running restart-counts pod-uids new-jobs; do
    [ -f "${BASELINE}/${file}" ]
    [ ! -s "${BASELINE}/${file}" ]
  done
}

# Restart counts

@test "record-baseline records each live pod of a long-running workload with its restart count" {
  workload Deployment api api/deployment.yaml
  workload StatefulSet db db/statefulset.yaml
  live_pod api-7c9d8f5b6-zz81p app=api Running 3
  live_pod api-7c9d8f5b6-x2k4q app=api Running 0
  live_pod db-0 app=db Running 1
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-7c9d8f5b6-x2k4q|0
api-7c9d8f5b6-zz81p|3
db-0|1" ]
}

@test "record-baseline records the uid of each of those pods beside its count" {
  workload Deployment api api/deployment.yaml
  workload StatefulSet db db/statefulset.yaml
  live_pod api-7c9d8f5b6-zz81p app=api Running 3
  live_pod db-0 app=db Running 1
  live_pod stranger-1 app=stranger Running 4
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/pod-uids")" = "api-7c9d8f5b6-zz81p|uid-of-api-7c9d8f5b6-zz81p
db-0|uid-of-db-0" ]
}

@test "record-baseline finds pods labelled app.kubernetes.io/name as well as app" {
  workload Deployment api api/deployment.yaml app.kubernetes.io/name=api
  live_pod api-new app.kubernetes.io/name=api Running 2
  live_pod api-old app=api Running 4
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-new|2
api-old|4" ]
}

@test "record-baseline sums the restarts of every container and init container in a pod" {
  workload Deployment api api/deployment.yaml
  live_pod api-1 app=api Running 2 5 init:1 init:10
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-1|18" ]
}

@test "record-baseline gives a pod with no container statuses yet a count of zero" {
  workload Deployment api api/deployment.yaml
  live_pod api-1 app=api Pending
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-1|0" ]
}

@test "record-baseline leaves out pods that have finished or are being deleted, and keeps the rest" {
  workload Deployment api api/deployment.yaml
  live_pod api-pending app=api Pending 0
  live_pod api-running app=api Running 1
  live_pod api-unknown app=api Unknown 2
  live_pod api-succeeded app=api Succeeded 3
  live_pod api-failed app=api Failed 4
  LIVE_POD_DELETING=true live_pod api-deleting app=api Running 5
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-pending|0
api-running|1
api-unknown|2" ]
}

@test "record-baseline records only the pods of long-running workloads: not a Job's, a CronJob's or anything undeclared" {
  workload Deployment api api/deployment.yaml
  workload Job migrate api/job-migrate.yaml
  workload CronJob nightly reports/cronjob-nightly.yaml
  live_pod api-1 app=api Running 0
  live_pod migrate-abcde app=migrate Running 2
  live_pod nightly-12345-abcde app=nightly Running 3
  live_pod stranger-1 app=stranger Running 4
  live_pod unlabelled-1 none Running 5
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-1|0" ]
}

@test "record-baseline takes a bare Pod to be its own pod, whatever its labels" {
  workload Pod probe pod-probe.yaml none
  live_pod probe none Running 6
  live_pod probe-lookalike app=probe Running 1
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "probe|6" ]
}

@test "record-baseline logs a workload whose pod template carries neither label, records none of its pods and carries on" {
  workload Deployment api api/deployment.yaml none
  workload StatefulSet db db/statefulset.yaml
  live_pod api-1 app=api Running 3
  live_pod db-0 app=db Running 1
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "db-0|1" ]
  grep -qF "Deployment api has neither app nor app.kubernetes.io/name set to its name on its pod template, so its pods cannot be found: api/deployment.yaml" "${TEST_RUN_BASE}/work/container.log"
}

@test "record-baseline treats a label naming something else as no label at all" {
  workload Deployment api api/deployment.yaml app=backend
  live_pod api-1 app=backend Running 3
  live_pod api-2 app=api Running 1
  run record-baseline
  [ "$status" -eq 0 ]
  [ ! -s "${BASELINE}/restart-counts" ]
  grep -qF "Deployment api has neither app nor app.kubernetes.io/name set to its name" "${TEST_RUN_BASE}/work/container.log"
}

@test "record-baseline writes a pod once when two workloads of the same name both find it" {
  workload Deployment api api/deployment.yaml
  workload Rollout api api/rollout.yaml
  live_pod api-1 app=api Running 2
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/restart-counts")" = "api-1|2" ]
}

@test "record-baseline reads the namespace's pods once, however many workloads there are" {
  workload Deployment api api/deployment.yaml
  workload StatefulSet db db/statefulset.yaml
  workload DaemonSet agent agent/daemonset.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(grep -cxF -- "get pods -o json" "${K_LOG}")" -eq 1 ]
}

@test "record-baseline says how many pods it recorded and names each one that has restarted" {
  workload Deployment api api/deployment.yaml
  live_pod api-1 app=api Running 0
  live_pod api-2 app=api Running 3
  run record-baseline
  [ "$status" -eq 0 ]
  grep -qF "Workloads declared: 1, to check: 1, long-running: 1, new Jobs: 0" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "Recorded restart counts for 2 pod(s), 1 have restarted" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "api-2 has restarted 3 time(s)" "${TEST_RUN_BASE}/work/container.log"
  run grep -F "api-1 has restarted" "${TEST_RUN_BASE}/work/container.log"
  [ "$status" -eq 1 ]
}

@test "record-baseline fails when the pods cannot be read" {
  workload Deployment api api/deployment.yaml
  cluster_fails pods
  run record-baseline
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not read the pods in run-test-env to record their restart counts"* ]]
}

# New Jobs

@test "record-baseline lists a declared Job the cluster does not have yet as new" {
  workload Job migrate-v42 api/job-migrate.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/new-jobs")" = "Job|migrate-v42|api/job-migrate.yaml" ]
}

@test "record-baseline does not list a declared Job that is already in the cluster" {
  workload Job migrate-v41 api/job-migrate-v41.yaml
  workload Job migrate-v42 api/job-migrate-v42.yaml
  cluster_holds "${MANIFESTS}/api/job-migrate-v41.yaml"
  run record-baseline
  [ "$status" -eq 0 ]
  [ "$(<"${BASELINE}/new-jobs")" = "Job|migrate-v42|api/job-migrate-v42.yaml" ]
}

@test "record-baseline asks the cluster about Jobs only" {
  workload Deployment api api/deployment.yaml
  workload Job migrate api/job-migrate.yaml
  workload CronJob nightly reports/cronjob-nightly.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  grep -qxF -- "get -f ${MANIFESTS}/api/job-migrate.yaml -o name" "${K_LOG}"
  [ "$(grep -c -- "get -f" "${K_LOG}")" -eq 1 ]
}

@test "record-baseline fails when the cluster cannot be asked whether a Job is there" {
  workload Job migrate api/job-migrate.yaml
  cluster_fails get
  run record-baseline
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not ask the cluster whether Job migrate is already there"* ]]
  [[ "$output" == *"Forbidden"* ]]
}

# The whole

@test "record-baseline changes nothing in the cluster" {
  workload Deployment api api/deployment.yaml
  workload Job migrate api/job-migrate.yaml
  live_pod api-1 app=api Running 0
  run record-baseline
  [ "$status" -eq 0 ]
  run grep -v -- "^get " "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "record-baseline takes the list of images in use before the deploy, into the baseline" {
  workload Deployment api api/deployment.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  [ -f "${BASELINE}/oci-images/oci-images-before-sorted" ]
  [ -f "${BASELINE}/oci-images/oci-images-before-unsorted" ]
  [ ! -e "${TEST_RUN_BASE}/work/oci-images" ]
}

@test "record-baseline refuses to run a second time in the same container" {
  workload Deployment api api/deployment.yaml
  run record-baseline
  [ "$status" -eq 0 ]
  live_pod api-1 app=api Running 7
  run record-baseline
  [ "$status" -ne 0 ]
  [[ "$output" == *"The baseline has already been recorded in this container, refusing to record it again"* ]]
  [ ! -s "${BASELINE}/restart-counts" ]
}

@test "record-baseline fails when there are no manifests" {
  run record-baseline
  [ "$status" -eq 43 ]
  [[ "$output" == *"No manifest files found to record a baseline for"* ]]
  [ ! -e "${BASELINE}" ]
}
