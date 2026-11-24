#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for monitor-environment: after a deploy, everything declared has to
# come up and stay up with no pod restarting, or the deploy fails.
#
# The clock and sleep are mocks, so a test runs in no time and still sees how
# long the script thinks it waited. The cluster is described round by round:
# what a test says at round N is what the script is told from its Nth ask on,
# until a later round says otherwise.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  install_mock_clock
  clock_reads 1000
  install_mock_sleep_that_moves_the_clock
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl" "${TEST_RUN_BASE}/work/baseline" "${TEST_RUN_BASE}/work/manifests"
  export ENVIRONMENT="run-omg"
  export ENVIRONMENT_TYPE="env"
  MANIFESTS="${TEST_RUN_BASE}/work/manifests"
  BASELINE="${TEST_RUN_BASE}/work/baseline"
  CLUSTER="${TEST_RUN_BASE}/work/mock-k-cluster"
  SNAPSHOT="${CLUSTER}/snapshot"
  SENT="${TEST_RUN_BASE}/work/notifications.log"
  SLEEPS="${TEST_RUN_BASE}/work/sleeps.log"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
  : > "${BASELINE}/long-running"
  : > "${BASELINE}/new-jobs"
  : > "${BASELINE}/restart-counts"
  : > "${BASELINE}/pod-uids"
  ROUND=1
}

teardown() {
  teardown_test_dirs
}

# What was declared and recorded before the deploy

# A long-running workload: its kind, its name, and the one label its pod
# template carries (app=<name> unless said, or none)
declared() {
  local kind="$1"
  local name="$2"
  local label="${3:-app=${name}}"
  local relative="${name}/${kind,,}.yaml"
  mkdir -p "${MANIFESTS}/${name}"

  local labels="{}"
  if [[ "${label}" != "none" ]]; then
    labels="{\"${label%%=*}\": \"${label#*=}\"}"
  fi

  if [[ "${kind}" == "Pod" ]]; then
    printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  labels: %s\nspec:\n  containers:\n    - name: main\n      image: example.org/thing:1.0.0\n' \
      "${name}" "${labels}" > "${MANIFESTS}/${relative}"
  else
    printf 'apiVersion: example.org/v1\nkind: %s\nmetadata:\n  name: %s\nspec:\n  template:\n    metadata:\n      labels: %s\n    spec:\n      containers:\n        - name: main\n          image: example.org/thing:1.0.0\n' \
      "${kind}" "${name}" "${labels}" > "${MANIFESTS}/${relative}"
  fi
  echo "${kind}|${name}|${relative}" >> "${BASELINE}/long-running"
}

# A Job this deploy brought: its name and the file it is in (job-<name>.yaml
# unless said). JOB_SUSPENDED=true makes it a suspended one and JOB_WAIT=<value>
# sets the annotation that says whether it is waited for.
new_job() {
  local name="$1"
  local relative="${2:-job-${name}.yaml}"
  mkdir -p "$(dirname "${MANIFESTS}/${relative}")"
  {
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: %s\n' "${name}"
    if [[ -n "${JOB_WAIT:-}" ]]; then
      printf '  annotations:\n    kaptain.org/main-deploy-job-wait: "%s"\n' "${JOB_WAIT}"
    fi
    printf 'spec:\n'
    if [[ "${JOB_SUSPENDED:-false}" == "true" ]]; then
      printf '  suspend: true\n'
    fi
    printf '  template:\n    spec:\n      containers:\n        - name: main\n          image: example.org/thing:1.0.0\n'
  } > "${MANIFESTS}/${relative}"
  echo "Job|${name}|${relative}" >> "${BASELINE}/new-jobs"
}

# A pod that was there before the deploy, and the restart count it had
restarted_before() {
  echo "$1|$2" >> "${BASELINE}/restart-counts"
  echo "$1|uid-of-$1" >> "${BASELINE}/pod-uids"
}

# What the cluster says, from a round on

# Everything said after this is how the cluster is from that ask on. A round
# starts empty: say all of it again.
from_round() {
  ROUND="$1"
  mkdir -p "${SNAPSHOT}/${ROUND}"
}

# A Deployment or StatefulSet as its controller reports it: kind, name, how
# many it desires, how many are on the current version, how many there are of
# any version, how many of any version are ready. The current version is a
# Deployment's revision 2 and a StatefulSet's revision <name>-2. OBSERVED=false
# in front is a controller that has not looked at the latest spec yet.
controller_says() {
  local kind="$1"
  local name="$2"
  local observed=2
  if [[ "${OBSERVED:-true}" == "false" ]]; then
    observed=1
  fi
  mkdir -p "${SNAPSHOT}/${ROUND}"
  printf '{"kind":"%s","metadata":{"name":"%s","generation":2,"annotations":{"deployment.kubernetes.io/revision":"2"}},"spec":{"replicas":%s},"status":{"observedGeneration":%s,"updatedReplicas":%s,"replicas":%s,"readyReplicas":%s,"updateRevision":"%s-2"}}' \
    "${kind}" "${name}" "$3" "${observed}" "$4" "$5" "$6" "${name}" > "${SNAPSHOT}/${ROUND}/${kind}-${name}"
}

# One of a Deployment's ReplicaSets: the Deployment, which revision it is (2 is
# the current one), how many pods it has and how many of them are ready
replicaset_says() {
  mkdir -p "${SNAPSHOT}/${ROUND}"
  printf '{"kind":"ReplicaSet","metadata":{"name":"%s-revision-%s","annotations":{"deployment.kubernetes.io/revision":"%s"},"ownerReferences":[{"kind":"Deployment","name":"%s"}]},"status":{"replicas":%s,"readyReplicas":%s}}' \
    "$1" "$2" "$2" "$1" "$3" "$4" > "${SNAPSHOT}/${ROUND}/ReplicaSet-$1-$2"
}

# A DaemonSet as its controller reports it: name, desired, on the current
# version, of any version, ready of any version. Its current template
# generation is 2.
daemonset_says() {
  mkdir -p "${SNAPSHOT}/${ROUND}"
  printf '{"kind":"DaemonSet","metadata":{"name":"%s","generation":2,"annotations":{"deprecated.daemonset.template.generation":"2"}},"status":{"observedGeneration":2,"desiredNumberScheduled":%s,"updatedNumberScheduled":%s,"currentNumberScheduled":%s,"numberReady":%s}}' \
    "$1" "$2" "$3" "$4" "$5" > "${SNAPSHOT}/${ROUND}/DaemonSet-$1"
}

# A Job: its name and how it is doing: running, retrying (a pod of it has
# failed and it is trying again), Complete or Failed
job_is() {
  local name="$1"
  local status
  case "$2" in
    running) status='{"active":1}' ;;
    retrying) status='{"active":1,"failed":2}' ;;
    Complete) status='{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}' ;;
    Failed) status='{"failed":7,"conditions":[{"type":"Failed","status":"True","reason":"BackoffLimitExceeded","message":"Job has reached the specified backoff limit"}]}' ;;
  esac
  mkdir -p "${SNAPSHOT}/${ROUND}"
  printf '{"kind":"Job","metadata":{"name":"%s"},"status":%s}' "${name}" "${status}" > "${SNAPSHOT}/${ROUND}/Job-${name}"
}

# A pod: its name, the one label it carries (key=value, or none), ready or
# not, and how many times it has restarted. Then, for one worth saying more
# about: its phase (Running unless said), why its container waits, and how its
# container last exited as a reason and an exit code.
#
# In front of it: POD_DELETING=true is one being deleted, POD_UID=<uid> one
# that is not the pod of that name the baseline saw (uid-of-<name> otherwise),
# POD_REVISION=<revision> the StatefulSet revision it is on and
# POD_GENERATION=<n> the DaemonSet template generation it is on.
pod_is() {
  local name="$1"
  local label="$2"
  local ready="False"
  if [[ "$3" == "ready" ]]; then
    ready="True"
  fi
  local restarts="$4"
  local phase="${5:-Running}"
  local waiting="${6:-}"
  local exit_reason="${7:-}"
  local exit_code="${8:-}"

  local labels="\"placeholder\":\"label\""
  if [[ "${label}" != "none" ]]; then
    labels+=",\"${label%%=*}\":\"${label#*=}\""
  fi
  if [[ -n "${POD_REVISION:-}" ]]; then
    labels+=",\"controller-revision-hash\":\"${POD_REVISION}\""
  fi
  if [[ -n "${POD_GENERATION:-}" ]]; then
    labels+=",\"pod-template-generation\":\"${POD_GENERATION}\""
  fi
  local deleting=""
  if [[ "${POD_DELETING:-false}" == "true" ]]; then
    deleting=',"deletionTimestamp":"2026-11-25T00:00:00Z"'
  fi
  local state='{"running":{}}'
  if [[ -n "${waiting}" ]]; then
    state="{\"waiting\":{\"reason\":\"${waiting}\"}}"
  fi
  local last_state='{}'
  if [[ -n "${exit_reason}" ]]; then
    last_state="{\"terminated\":{\"reason\":\"${exit_reason}\",\"exitCode\":${exit_code}}}"
  fi

  mkdir -p "${SNAPSHOT}/${ROUND}"
  printf '{"kind":"Pod","metadata":{"name":"%s","uid":"%s","labels":{%s}%s},"status":{"phase":"%s","conditions":[{"type":"Ready","status":"%s"}],"containerStatuses":[{"name":"main","restartCount":%s,"state":%s,"lastState":%s}]}}' \
    "${name}" "${POD_UID:-uid-of-${name}}" "${labels}" "${deleting}" "${phase}" "${ready}" "${restarts}" "${state}" "${last_state}" \
    > "${SNAPSHOT}/${ROUND}/Pod-${name}"
}

sleeps() {
  tr '\n' ' ' < "${SLEEPS}"
}

# The whole of a run, as the chat thread sees it

@test "monitor-environment follows a workload coming up one pod at a time, then calls the environment stable once it has stayed up" {
  declared Deployment api
  from_round 1
  controller_says Deployment api 3 1 3 2
  replicaset_says api 2 1 0
  replicaset_says api 1 2 2
  from_round 2
  controller_says Deployment api 3 2 3 2
  replicaset_says api 2 2 1
  replicaset_says api 1 1 1
  from_round 3
  controller_says Deployment api 3 3 3 2
  from_round 4
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 600 seconds
INFO: Environment current state:
  api deployment desires 3, has 1 pod, of which 0 are ready
INFO: Environment current state:
  api deployment desires 3, has 2 pods, of which 1 is ready
INFO: Environment current state:
  api deployment desires 3, has 3 pods, of which 2 are ready
INFO: Environment declared stable!" ]
  [ "$(sleeps)" = "5 5 5 5 5 " ]
}

@test "monitor-environment says only that it started and that the environment is stable when nothing needed waiting for" {
  declared Deployment api
  declared StatefulSet db
  controller_says Deployment api 3 3 3 3
  controller_says StatefulSet db 1 1 1 1
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 600 seconds
INFO: Environment declared stable!" ]
  [ "$(sleeps)" = "5 5 " ]
}

@test "monitor-environment says a state that lasts once, then how long it lasted ahead of the next" {
  declared Deployment api
  from_round 1
  controller_says Deployment api 3 1 1 0
  from_round 6
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 600 seconds
INFO: Environment current state:
  api deployment desires 3, has 1 pod, of which 0 are ready
INFO: Prior message repeated 4 times over 35s
INFO: Environment declared stable!" ]
}

@test "monitor-environment lists only what is not yet as it should be" {
  declared Deployment api
  declared Deployment billing
  declared StatefulSet db
  declared DaemonSet agent
  from_round 1
  controller_says Deployment api 3 1 1 0
  controller_says Deployment billing 2 2 2 2
  controller_says StatefulSet db 1 1 1 0
  daemonset_says agent 5 2 2 2
  from_round 2
  controller_says Deployment api 3 3 3 3
  controller_says Deployment billing 2 2 2 2
  controller_says StatefulSet db 1 1 1 1
  daemonset_says agent 5 5 5 5
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,5p "${SENT}")" = "INFO: Environment current state:
  api deployment desires 3, has 1 pod, of which 0 are ready
  db statefulset desires 1, has 1 pod, of which 0 are ready
  agent daemonset desires 5, has 2 pods, of which 2 are ready" ]
  run grep -F "billing" "${SENT}"
  [ "$status" -eq 1 ]
}

# What counts as a workload being as it should be

@test "monitor-environment counts a Deployment's ready pods from its current ReplicaSet while another still has pods" {
  declared Deployment api
  from_round 1
  controller_says Deployment api 3 2 4 3
  replicaset_says api 2 2 1
  replicaset_says api 1 2 2
  from_round 2
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,3p "${SENT}")" = "INFO: Environment current state:
  api deployment desires 3, has 2 pods, of which 1 is ready" ]
}

@test "monitor-environment counts a StatefulSet's ready pods from those on its current revision while others are not" {
  declared StatefulSet db
  from_round 1
  controller_says StatefulSet db 3 2 3 2
  POD_REVISION=db-2 pod_is db-2 app=db ready 0
  POD_REVISION=db-2 pod_is db-1 app=db unready 0
  POD_REVISION=db-1 pod_is db-0 app=db ready 0
  from_round 2
  controller_says StatefulSet db 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,3p "${SENT}")" = "INFO: Environment current state:
  db statefulset desires 3, has 2 pods, of which 1 is ready" ]
}

@test "monitor-environment counts a DaemonSet's ready pods from those on its current template generation while others are not" {
  declared DaemonSet agent
  from_round 1
  daemonset_says agent 4 2 4 3
  POD_GENERATION=2 pod_is agent-aaaaa app=agent ready 0
  POD_GENERATION=2 pod_is agent-bbbbb app=agent unready 0
  POD_GENERATION=1 pod_is agent-ccccc app=agent ready 0
  POD_GENERATION=1 pod_is agent-ddddd app=agent ready 0
  from_round 2
  daemonset_says agent 4 4 4 4
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,3p "${SENT}")" = "INFO: Environment current state:
  agent daemonset desires 4, has 2 pods, of which 1 is ready" ]
}

@test "monitor-environment is not held up by pods of the version on its way out" {
  declared Deployment api
  controller_says Deployment api 3 3 4 4
  replicaset_says api 2 3 3
  replicaset_says api 1 1 1
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${SENT}")" -eq 2 ]
}

@test "monitor-environment asks for the ReplicaSets only in a round where a Deployment is part way through a rollout, and once however many are" {
  declared Deployment api
  declared Deployment billing
  from_round 1
  controller_says Deployment api 3 1 3 2
  controller_says Deployment billing 2 1 2 1
  replicaset_says api 2 1 0
  replicaset_says api 1 2 2
  replicaset_says billing 2 1 0
  replicaset_says billing 1 1 1
  from_round 2
  controller_says Deployment api 3 3 3 3
  controller_says Deployment billing 2 2 2 2
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(grep -cxF -- "get replicasets -o json" "${K_LOG}")" -eq 1 ]
  [ "$(sed -n 2,4p "${SENT}")" = "INFO: Environment current state:
  api deployment desires 3, has 1 pod, of which 0 are ready
  billing deployment desires 2, has 1 pod, of which 0 are ready" ]
}

@test "monitor-environment counts nothing as there while the controller has not looked at the latest spec" {
  declared Deployment api
  from_round 1
  OBSERVED=false controller_says Deployment api 3 3 3 3
  from_round 2
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,3p "${SENT}")" = "INFO: Environment current state:
  api deployment desires 3, has 0 pods, of which 0 are ready" ]
}

@test "monitor-environment takes a workload scaled to nothing as being as it should be" {
  declared Deployment deployer
  controller_says Deployment deployer 0 0 0 0
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${SENT}")" -eq 2 ]
}

@test "monitor-environment says a declared workload is not in the cluster" {
  export MONITOR_ENVIRONMENT_TIMEOUT=0
  declared Deployment api
  run monitor-environment
  [ "$status" -eq 64 ]
  [[ "$output" == *"  api deployment is not in the cluster"* ]]
}

@test "monitor-environment judges a custom kind on its pods alone" {
  declared Rollout api
  from_round 1
  pod_is api-1 app=api ready 0
  pod_is api-2 app=api unready 0
  from_round 2
  pod_is api-1 app=api ready 0
  pod_is api-2 app=api ready 0
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,3p "${SENT}")" = "INFO: Environment current state:
  api rollout has 2 pods, of which 1 is ready" ]
}

@test "monitor-environment wants a bare Pod there and ready" {
  declared Pod probe none
  from_round 2
  pod_is probe none unready 0
  from_round 3
  pod_is probe none ready 0
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sed -n 2,5p "${SENT}")" = "INFO: Environment current state:
  probe pod desires 1, has 0 pods, of which 0 are ready
INFO: Environment current state:
  probe pod desires 1, has 1 pod, of which 0 are ready" ]
}

# Staying stable

@test "monitor-environment starts the wait to settle again when something stops being as it should be" {
  declared Deployment api
  from_round 1
  controller_says Deployment api 3 3 3 3
  from_round 2
  controller_says Deployment api 3 3 3 2
  from_round 3
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sleeps)" = "5 5 5 5 " ]
}

@test "monitor-environment takes how long the environment has to stay stable from the environment" {
  export MONITOR_ENVIRONMENT_SETTLE=0
  declared Deployment api
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ ! -e "${SLEEPS}" ]
  [ "$(grep -c -- "^get " "${K_LOG}")" -eq 1 ]
}

# Restarts

@test "monitor-environment fails at once when a pod new in this deploy restarts" {
  declared Deployment api
  controller_says Deployment api 3 3 3 2
  pod_is api-7c9d8f5b6-x2k4q app=api ready 0
  pod_is api-7c9d8f5b6-zz81p app=api unready 1 Running CrashLoopBackOff Error 1
  run monitor-environment
  [ "$status" -eq 63 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 600 seconds
INFO: Environment current state:
  api deployment desires 3, has 3 pods, of which 2 are ready
  api-7c9d8f5b6-zz81p restarted 1 time (was 0)
INFO: Unrecoverable issues were encountered, exiting early.
ERROR: Environment not stable:
  api-7c9d8f5b6-zz81p (api deployment) restarted 1 time (was 0), last exit Error (1)" ]
  [ ! -e "${SLEEPS}" ]
}

@test "monitor-environment fails when a pod of something this deploy did not change gains a restart" {
  declared Deployment billing
  restarted_before billing-5d7f9c6b8-q7x2m 3
  controller_says Deployment billing 1 1 1 1
  pod_is billing-5d7f9c6b8-q7x2m app=billing ready 4 Running "" OOMKilled 137
  run monitor-environment
  [ "$status" -eq 63 ]
  [ "$(sed -n 2,6p "${SENT}")" = "INFO: Environment current state:
  billing-5d7f9c6b8-q7x2m restarted 4 times (was 3)
INFO: Unrecoverable issues were encountered, exiting early.
ERROR: Environment not stable:
  billing-5d7f9c6b8-q7x2m (billing deployment) restarted 4 times (was 3), last exit OOMKilled (137)" ]
}

@test "monitor-environment holds a pod to the count it had before, not to zero" {
  declared Deployment billing
  restarted_before billing-5d7f9c6b8-q7x2m 3
  controller_says Deployment billing 1 1 1 1
  pod_is billing-5d7f9c6b8-q7x2m app=billing ready 3
  run monitor-environment
  [ "$status" -eq 0 ]
}

@test "monitor-environment holds a pod that replaced one of the same name to zero, not to the count the old one had" {
  declared StatefulSet db
  restarted_before db-0 3
  controller_says StatefulSet db 1 1 1 1
  POD_UID=uid-of-the-replacement pod_is db-0 app=db ready 1
  run monitor-environment
  [ "$status" -eq 63 ]
  [[ "$output" == *"db-0 (db statefulset) restarted 1 time (was 0)"* ]]
}

@test "monitor-environment fails on a restart during the wait to settle" {
  declared Deployment api
  from_round 1
  controller_says Deployment api 1 1 1 1
  pod_is api-1 app=api ready 0
  from_round 2
  controller_says Deployment api 1 1 1 1
  pod_is api-1 app=api ready 1
  run monitor-environment
  [ "$status" -eq 63 ]
  [[ "$output" == *"api-1 restarted 1 time (was 0)"* ]]
}

@test "monitor-environment finds a workload's pods by either label" {
  declared Deployment api app.kubernetes.io/name=api
  controller_says Deployment api 2 2 2 2
  pod_is api-new app.kubernetes.io/name=api ready 1
  run monitor-environment
  [ "$status" -eq 63 ]
  [[ "$output" == *"api-new (api deployment) restarted 1 time (was 0)"* ]]
}

@test "monitor-environment does not watch the restarts of pods that are not a declared workload's" {
  declared Deployment api
  controller_says Deployment api 1 1 1 1
  pod_is api-1 app=api ready 0
  pod_is stranger-1 app=stranger ready 9
  pod_is unlabelled-1 none ready 9
  run monitor-environment
  [ "$status" -eq 0 ]
}

@test "monitor-environment does not watch the restarts of a pod that has finished or is being deleted" {
  declared Deployment api
  controller_says Deployment api 1 1 1 1
  pod_is api-1 app=api ready 0
  pod_is api-finished app=api unready 5 Succeeded
  pod_is api-failed app=api unready 5 Failed
  POD_DELETING=true pod_is api-going app=api ready 5
  run monitor-environment
  [ "$status" -eq 0 ]
}

@test "monitor-environment cannot watch the restarts of a workload whose pod template carries neither label, and says so in the log" {
  declared Deployment api none
  controller_says Deployment api 1 1 1 1
  pod_is api-1 app=api ready 5
  run monitor-environment
  [ "$status" -eq 0 ]
  grep -qF "Deployment api has neither app nor app.kubernetes.io/name set to its name on its pod template, so its pods cannot be found and their restarts are not watched" "${TEST_RUN_BASE}/work/container.log"
}

# Jobs

@test "monitor-environment waits for a Job this deploy brought, through its retries, until it is Complete" {
  new_job migrate
  from_round 1
  job_is migrate running
  from_round 2
  job_is migrate retrying
  from_round 3
  job_is migrate running
  from_round 4
  job_is migrate Complete
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 600 seconds
INFO: Environment current state:
  migrate job is still running
INFO: Environment current state:
  migrate job failed but has retries left
INFO: Environment current state:
  migrate job is still running
INFO: Environment declared stable!" ]
}

@test "monitor-environment fails at once when a Job has Failed, in the Job's own words" {
  declared Deployment api
  new_job import
  controller_says Deployment api 3 2 2 1
  job_is import Failed
  run monitor-environment
  [ "$status" -eq 63 ]
  [ "$(sed -n 2,7p "${SENT}")" = "INFO: Environment current state:
  api deployment desires 3, has 2 pods, of which 1 is ready
  import job has failed and exhausted retries
INFO: Unrecoverable issues were encountered, exiting early.
ERROR: Environment not stable:
  import job: BackoffLimitExceeded: Job has reached the specified backoff limit" ]
}

@test "monitor-environment leaves prerequisite and postdeploy Jobs to apply-jobs" {
  new_job migrate api/prerequisite-job-migrate.yaml
  new_job announce postdeploy-job-announce.yaml
  job_is migrate Failed
  job_is announce running
  run monitor-environment
  [ "$status" -eq 0 ]
}

@test "monitor-environment does not wait for a suspended Job, or one annotated kaptain.org/main-deploy-job-wait false" {
  JOB_SUSPENDED=true new_job paused
  JOB_WAIT=false new_job background
  job_is paused running
  job_is background Failed
  run monitor-environment
  [ "$status" -eq 0 ]
  grep -qF "Job paused is suspended, not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "Job background is annotated kaptain.org/main-deploy-job-wait: \"false\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
}

@test "monitor-environment does not wait for a Job the cluster had before this deploy" {
  job_is old-migrate Failed
  run monitor-environment
  [ "$status" -eq 0 ]
}

@test "monitor-environment stops waiting for a Job that is gone from the cluster" {
  new_job migrate
  run monitor-environment
  [ "$status" -eq 0 ]
  grep -qF "Job migrate is gone from the cluster" "${TEST_RUN_BASE}/work/container.log"
}

# Running out of time

@test "monitor-environment gives up when the time runs out, saying what was not stable and what its pods were doing" {
  export MONITOR_ENVIRONMENT_TIMEOUT=20
  declared Deployment api
  declared Deployment billing
  new_job migrate
  controller_says Deployment api 3 2 3 3
  replicaset_says api 2 2 2
  replicaset_says api 1 1 1
  controller_says Deployment billing 1 1 1 1
  pod_is api-7c9d8f5b6-aaaaa app=api ready 0
  pod_is api-7c9d8f5b6-x2k4q app=api unready 0 Pending ImagePullBackOff
  job_is migrate running
  run monitor-environment
  [ "$status" -eq 64 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 20 seconds
INFO: Environment current state:
  api deployment desires 3, has 2 pods, of which 2 are ready
  migrate job is still running
INFO: Prior message repeated 4 times over 20s
INFO: Stability check timed out.
ERROR: Environment not stable after 20 seconds. Bailing...
  api deployment desires 3, has 2 pods, of which 2 are ready
    has 2 active replicasets
    api-7c9d8f5b6-x2k4q is Pending: ImagePullBackOff
  migrate job is still running" ]
}

@test "monitor-environment says why a pod that cannot be scheduled is waiting" {
  export MONITOR_ENVIRONMENT_TIMEOUT=0
  declared StatefulSet db
  controller_says StatefulSet db 1 1 1 0
  printf '{"kind":"Pod","metadata":{"name":"db-0","labels":{"app":"db"}},"status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable"}]}}' \
    > "${SNAPSHOT}/1/Pod-db-0"
  run monitor-environment
  [ "$status" -eq 64 ]
  [[ "$output" == *"  db statefulset desires 1, has 1 pod, of which 0 are ready
    db-0 is Pending: Unschedulable"* ]]
}

# The cluster not answering

@test "monitor-environment asks again next round when the cluster cannot be read, and carries on" {
  declared Deployment api
  controller_says Deployment api 3 3 3 3
  echo 2 > "${CLUSTER}/snapshot-fails"
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Starting stability check for 'run-omg' with timeout of 600 seconds
INFO: Environment current state:
  The state of the environment could not be read
INFO: Prior message repeated 1 time over 20s
INFO: Environment declared stable!" ]
  grep -qF "Could not read the state of run-omg: Error from server (Forbidden)" "${TEST_RUN_BASE}/work/container.log"
}

@test "monitor-environment gives up like any other wait when the cluster can never be read" {
  export MONITOR_ENVIRONMENT_TIMEOUT=10
  declared Deployment api
  mkdir -p "${CLUSTER}"
  : > "${CLUSTER}/snapshot-fails"
  run monitor-environment
  [ "$status" -eq 64 ]
  [ "$(sed -n 2,7p "${SENT}")" = "INFO: Environment current state:
  The state of the environment could not be read
INFO: Prior message repeated 2 times over 10s
INFO: Stability check timed out.
ERROR: Environment not stable after 10 seconds. Bailing...
  The state of the environment could not be read: Error from server (Forbidden): deployments.apps is forbidden" ]
}

# How often it asks

@test "monitor-environment asks every 5s for the first minute, then 10s, then 20s, then 40s from there on" {
  declared Deployment api
  from_round 1
  controller_says Deployment api 3 1 1 0
  from_round 26
  controller_says Deployment api 3 3 3 3
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(sleeps)" = "5 5 5 5 5 5 5 5 5 5 5 5 10 10 10 10 10 10 20 20 20 40 40 40 40 10 " ]
}

@test "monitor-environment takes its timeout and its pauses from the environment, and never pauses past the timeout" {
  export MONITOR_ENVIRONMENT_TIMEOUT=25
  export MONITOR_ENVIRONMENT_POLL=3
  export MONITOR_ENVIRONMENT_POLL_DOUBLE_AFTER=10
  export MONITOR_ENVIRONMENT_POLL_DOUBLES=2
  declared Deployment api
  controller_says Deployment api 3 1 1 0
  run monitor-environment
  [ "$status" -eq 64 ]
  [ "$(sleeps)" = "3 3 3 3 6 6 1 " ]
  [[ "$output" == *"Environment not stable after 25 seconds. Bailing..."* ]]
}

@test "monitor-environment asks the cluster once a round, and changes nothing in it" {
  declared Deployment api
  declared StatefulSet db
  new_job migrate
  from_round 1
  controller_says Deployment api 3 1 1 0
  controller_says StatefulSet db 1 1 1 0
  job_is migrate running
  from_round 3
  controller_says Deployment api 3 3 3 3
  controller_says StatefulSet db 1 1 1 1
  job_is migrate Complete
  run monitor-environment
  [ "$status" -eq 0 ]
  [ "$(grep -cxF -- "get deployments,statefulsets,daemonsets,jobs,pods -o json" "${K_LOG}")" -eq 5 ]
  [ "$(wc -l < "${K_LOG}")" -eq 5 ]
}

# Going wrong itself

@test "monitor-environment fails when there is no baseline to hold the environment to" {
  rm "${BASELINE}/restart-counts"
  run monitor-environment
  [ "$status" -ne 0 ]
  [ "$status" -ne 63 ]
  [ "$status" -ne 64 ]
  [[ "$output" == *"No baseline to hold the environment to, record-baseline has to run first"* ]]
  [ ! -e "${K_LOG}" ]
}
