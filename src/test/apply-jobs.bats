#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for apply-jobs: a job stage is applied, and the Jobs in it that this
# deploy brought are waited for, all together.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  install_mock_sleep
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl" "${TEST_RUN_BASE}/work/baseline"
  export ENVIRONMENT="run-test-env"
  export ENVIRONMENT_TYPE="env"
  PREREQUISITE="${TEST_RUN_BASE}/work/stages/prerequisite"
  POSTDEPLOY="${TEST_RUN_BASE}/work/stages/postdeploy"
  NEW_JOBS="${TEST_RUN_BASE}/work/baseline/new-jobs"
  SENT="${TEST_RUN_BASE}/work/notifications.log"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
  : > "${NEW_JOBS}"
}

teardown() {
  teardown_test_dirs
}

# A Job in a stage: the stage, where in it, its name. It is new to the cluster,
# so in the baseline's new-jobs, unless JOB_WAS_THERE=true is in front.
# JOB_SUSPENDED=true makes it a suspended one. JOB_WAIT=<value> sets the
# annotation that says whether a Job of its stage is waited for, or with
# JOB_WAIT_ANNOTATION=<name> an annotation of that name instead.
stage_job() {
  local stage="$1"
  local relative="$2"
  local name="$3"
  local file="${TEST_RUN_BASE}/work/stages/${stage}/${relative}"
  mkdir -p "$(dirname "${file}")"
  {
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: %s\n' "${name}"
    if [[ -n "${JOB_WAIT:-}" ]]; then
      printf '  annotations:\n    %s: "%s"\n' "${JOB_WAIT_ANNOTATION:-kaptain.org/${stage}-job-wait}" "${JOB_WAIT}"
    fi
    printf 'spec:\n'
    if [[ "${JOB_SUSPENDED:-false}" == "true" ]]; then
      printf '  suspend: true\n'
    fi
    printf '  template:\n    spec:\n      containers:\n        - name: main\n          image: example.org/thing:1.0.0\n'
  } > "${file}"
  if [[ "${JOB_WAS_THERE:-false}" != "true" ]]; then
    echo "Job|${name}|${relative}" >> "${NEW_JOBS}"
  fi
}

# Being called

@test "apply-jobs needs to be told which stage, and knows only the two" {
  run apply-jobs
  [ "$status" -eq 42 ]
  run apply-jobs deploy
  [ "$status" -eq 42 ]
  run apply-jobs prerequisite postdeploy
  [ "$status" -eq 42 ]
}

@test "apply-jobs does nothing when the stage is not there" {
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ ! -f "${K_LOG}" ]
  grep -qF "No prerequisite jobs" "${TEST_RUN_BASE}/work/container.log"
}

@test "apply-jobs fails when there are jobs and no baseline to tell which are new" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  rm "${NEW_JOBS}"
  run apply-jobs prerequisite
  [ "$status" -ne 0 ]
  [[ "$output" == *"No baseline to tell which prerequisite jobs are new, record-baseline has to run first"* ]]
  [ ! -f "${K_LOG}" ]
}

# Applying

@test "apply-jobs applies the whole stage in one apply, as the deploy applies anything" {
  stage_job prerequisite api/prerequisite-job-migrate.yaml migrate
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: migrate-config\n' > "${PREREQUISITE}/api/configmap.yaml"
  job_ends "${PREREQUISITE}/api/prerequisite-job-migrate.yaml" Complete
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  grep -qxF -- "apply --server-side --field-manager=kaptain/env/run-test-env -R -f ${PREREQUISITE}" "${K_LOG}"
  [ "$(grep -c -- "^apply " "${K_LOG}")" -eq 1 ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply-prerequisite.log" ]
}

@test "apply-jobs fails, and waits for nothing, when the apply fails" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  cluster_fails apply
  run apply-jobs prerequisite
  [ "$status" -ne 0 ]
  [[ "$output" == *"Applying the prerequisite jobs failed"* ]]
  run grep -- "^get " "${K_LOG}"
  [ "$status" -eq 1 ]
}

# Waiting

@test "apply-jobs passes once a new Job is Complete" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Complete
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: The prerequisite jobs have finished: 1 waited for" ]
}

@test "apply-jobs keeps asking about a Job that is still running, and says it is waiting once" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Complete 3
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^get -f" "${K_LOG}")" -eq 4 ]
  [ "$(sed -n 1p "${SENT}")" = "INFO: Waiting for 1 prerequisite job(s): migrate" ]
  [[ "$(sed -n 2p "${SENT}")" =~ ^INFO:\ Prior\ message\ repeated\ 2\ times\ over\ [0-9]+s$ ]]
  [ "$(sed -n 3p "${SENT}")" = "INFO: The prerequisite jobs have finished: 1 waited for" ]
  [ "$(wc -l < "${SENT}")" -eq 3 ]
}

@test "apply-jobs waits for all its Jobs together, and says so again as each one finishes" {
  stage_job prerequisite prerequisite-job-first.yaml first
  stage_job prerequisite prerequisite-job-second.yaml second
  job_ends "${PREREQUISITE}/prerequisite-job-first.yaml" Complete 1
  job_ends "${PREREQUISITE}/prerequisite-job-second.yaml" Complete 2
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Waiting for 2 prerequisite job(s): first, second
INFO: Waiting for 1 prerequisite job(s): second
INFO: The prerequisite jobs have finished: 2 waited for" ]
}

@test "apply-jobs stops asking about a Job once it is Complete" {
  stage_job prerequisite prerequisite-job-first.yaml first
  stage_job prerequisite prerequisite-job-second.yaml second
  job_ends "${PREREQUISITE}/prerequisite-job-first.yaml" Complete
  job_ends "${PREREQUISITE}/prerequisite-job-second.yaml" Complete 2
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "^get -f ${PREREQUISITE}/prerequisite-job-first.yaml" "${K_LOG}")" -eq 1 ]
  [ "$(grep -c -- "^get -f ${PREREQUISITE}/prerequisite-job-second.yaml" "${K_LOG}")" -eq 3 ]
}

@test "apply-jobs fails the deploy at once when a Job has Failed, in the Job's own words" {
  stage_job prerequisite prerequisite-job-first.yaml first
  stage_job prerequisite prerequisite-job-second.yaml second
  job_ends "${PREREQUISITE}/prerequisite-job-first.yaml" Failed
  job_ends "${PREREQUISITE}/prerequisite-job-second.yaml" Complete 5
  run apply-jobs prerequisite
  [ "$status" -eq 61 ]
  [[ "$output" == *"INFO: The prerequisite job first failed"* ]]
  [[ "$output" == *"ERROR: The prerequisite job first failed"* ]]
  [[ "$output" == *"BackoffLimitExceeded: Job has reached the specified backoff limit"* ]]
  [[ "$output" == *"kubectl -n run-test-env logs job/first"* ]]
  run grep -- "prerequisite-job-second.yaml" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "apply-jobs gives up with the names of the Jobs still running when the wait runs out" {
  export JOB_WAIT_TIMEOUT=0
  stage_job prerequisite prerequisite-job-first.yaml first
  stage_job prerequisite prerequisite-job-second.yaml second
  job_ends "${PREREQUISITE}/prerequisite-job-first.yaml" Complete
  run apply-jobs prerequisite
  [ "$status" -eq 62 ]
  [[ "$output" == *"INFO: Gave up waiting for the prerequisite jobs after 0s"* ]]
  [[ "$output" == *"ERROR: The prerequisite jobs did not all finish within 0s, still running: second"* ]]
}

@test "apply-jobs says a Job that is gone from the cluster cannot be told, and waits for it no longer" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_vanishes "${PREREQUISITE}/prerequisite-job-migrate.yaml"
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO: Job migrate is gone from the cluster, deleted or cleaned up by its ttlSecondsAfterFinished, so how it ended cannot be told. No longer waiting for it."* ]]
  [ "$(grep -c -- "^get -f" "${K_LOG}")" -eq 1 ]
}

@test "apply-jobs fails when the cluster cannot be asked about a Job" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  cluster_fails get
  run apply-jobs prerequisite
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: Could not ask the cluster about prerequisite job migrate: Error from server (Forbidden)"* ]]
}

# How often it asks

@test "apply-jobs asks every 5s for the first minute, then 10s, then 20s, then 40s from there on" {
  install_mock_clock
  clock_reads 1000
  install_mock_sleep_that_moves_the_clock
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Complete 25
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "${TEST_RUN_BASE}/work/sleeps.log")" = "5 5 5 5 5 5 5 5 5 5 5 5 10 10 10 10 10 10 20 20 20 40 40 40 40 " ]
  grep -qxF "INFO: Prior message repeated 24 times over 340s" "${SENT}"
}

@test "apply-jobs takes its fastest pause, how long before it doubles and how many times from the environment" {
  export JOB_WAIT_POLL=3
  export JOB_WAIT_POLL_DOUBLE_AFTER=10
  export JOB_WAIT_POLL_DOUBLES=2
  install_mock_clock
  clock_reads 1000
  install_mock_sleep_that_moves_the_clock
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Complete 9
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "${TEST_RUN_BASE}/work/sleeps.log")" = "3 3 3 3 6 6 12 12 12 " ]
}

@test "apply-jobs never pauses past the end of the wait" {
  export JOB_WAIT_TIMEOUT=12
  install_mock_clock
  clock_reads 1000
  install_mock_sleep_that_moves_the_clock
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  run apply-jobs prerequisite
  [ "$status" -eq 62 ]
  [ "$(tr '\n' ' ' < "${TEST_RUN_BASE}/work/sleeps.log")" = "5 5 2 " ]
  [[ "$output" == *"did not all finish within 12s"* ]]
}

# Which Jobs are waited for

@test "apply-jobs applies a Job the cluster already had, and does not wait for it" {
  JOB_WAS_THERE=true stage_job prerequisite prerequisite-job-migrate.yaml migrate
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  grep -q -- "^apply " "${K_LOG}"
  run grep -- "^get " "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "Job migrate was in the cluster before this deploy, not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  [ ! -e "${SENT}" ]
}

@test "apply-jobs does not wait for a suspended Job" {
  JOB_SUSPENDED=true stage_job prerequisite prerequisite-job-migrate.yaml migrate
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  run grep -- "^get " "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "Job migrate is suspended, not waiting for it" "${TEST_RUN_BASE}/work/container.log"
}

@test "apply-jobs asks only about Jobs, not what a prerequisite Job brought with it" {
  stage_job prerequisite api/prerequisite-job-migrate.yaml migrate
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: migrate-config\n' > "${PREREQUISITE}/api/configmap.yaml"
  job_ends "${PREREQUISITE}/api/prerequisite-job-migrate.yaml" Complete
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  run grep -- "^get -f ${PREREQUISITE}/api/configmap.yaml" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "apply-jobs waits for a postdeploy Job that does not say otherwise" {
  stage_job postdeploy postdeploy-job-announce.yaml announce
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Complete 1
  run apply-jobs postdeploy
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Waiting for 1 postdeploy job(s): announce
INFO: The postdeploy jobs have finished: 1 waited for" ]
}

@test "apply-jobs waits for a postdeploy Job annotated to be waited for" {
  JOB_WAIT=true stage_job postdeploy postdeploy-job-announce.yaml announce
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Failed
  run apply-jobs postdeploy
  [ "$status" -eq 61 ]
  [[ "$output" == *"ERROR: The postdeploy job announce failed"* ]]
}

@test "apply-jobs does not wait for a postdeploy Job annotated kaptain.org/postdeploy-job-wait false, even one that fails" {
  JOB_WAIT=false stage_job postdeploy postdeploy-job-announce.yaml announce
  stage_job postdeploy postdeploy-job-warm.yaml warm
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Failed
  job_ends "${POSTDEPLOY}/postdeploy-job-warm.yaml" Complete
  run apply-jobs postdeploy
  [ "$status" -eq 0 ]
  run grep -- "^get -f ${POSTDEPLOY}/postdeploy-job-announce.yaml" "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "Job announce is annotated kaptain.org/postdeploy-job-wait: \"false\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  [ "$(<"${SENT}")" = "INFO: The postdeploy jobs have finished: 1 waited for" ]
}

@test "apply-jobs does not wait for a prerequisite Job annotated kaptain.org/prerequisite-job-wait false, even one that fails" {
  JOB_WAIT=false stage_job prerequisite prerequisite-job-warm.yaml warm
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_ends "${PREREQUISITE}/prerequisite-job-warm.yaml" Failed
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Complete
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  grep -q -- "^apply " "${K_LOG}"
  run grep -- "^get -f ${PREREQUISITE}/prerequisite-job-warm.yaml" "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "Job warm is annotated kaptain.org/prerequisite-job-wait: \"false\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  [ "$(<"${SENT}")" = "INFO: The prerequisite jobs have finished: 1 waited for" ]
}

@test "apply-jobs takes each stage's annotation for that stage only" {
  JOB_WAIT=false JOB_WAIT_ANNOTATION=kaptain.org/postdeploy-job-wait stage_job prerequisite prerequisite-job-migrate.yaml migrate
  JOB_WAIT=false JOB_WAIT_ANNOTATION=kaptain.org/prerequisite-job-wait stage_job postdeploy postdeploy-job-announce.yaml announce
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Failed
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Failed
  run apply-jobs prerequisite
  [ "$status" -eq 61 ]
  run apply-jobs postdeploy
  [ "$status" -eq 61 ]
}

@test "apply-jobs waits for no prerequisite Job that does not say otherwise when PREREQUISITE_JOB_WAIT is false, and still applies them" {
  export PREREQUISITE_JOB_WAIT=false
  stage_job prerequisite prerequisite-job-first.yaml first
  stage_job prerequisite prerequisite-job-second.yaml second
  job_ends "${PREREQUISITE}/prerequisite-job-first.yaml" Failed
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  grep -qxF -- "apply --server-side --field-manager=kaptain/env/run-test-env -R -f ${PREREQUISITE}" "${K_LOG}"
  run grep -- "^get " "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "PREREQUISITE_JOB_WAIT is false and Job first is not annotated kaptain.org/prerequisite-job-wait: \"true\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "PREREQUISITE_JOB_WAIT is false and Job second is not annotated kaptain.org/prerequisite-job-wait: \"true\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  [ ! -e "${SENT}" ]
}

@test "apply-jobs waits for no postdeploy Job that does not say otherwise when POSTDEPLOY_JOB_WAIT is false, and still applies them" {
  export POSTDEPLOY_JOB_WAIT=false
  stage_job postdeploy postdeploy-job-announce.yaml announce
  stage_job postdeploy postdeploy-job-warm.yaml warm
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Failed
  run apply-jobs postdeploy
  [ "$status" -eq 0 ]
  grep -qxF -- "apply --server-side --field-manager=kaptain/env/run-test-env -R -f ${POSTDEPLOY}" "${K_LOG}"
  run grep -- "^get " "${K_LOG}"
  [ "$status" -eq 1 ]
  grep -qF "POSTDEPLOY_JOB_WAIT is false and Job announce is not annotated kaptain.org/postdeploy-job-wait: \"true\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  grep -qF "POSTDEPLOY_JOB_WAIT is false and Job warm is not annotated kaptain.org/postdeploy-job-wait: \"true\", not waiting for it" "${TEST_RUN_BASE}/work/container.log"
  [ ! -e "${SENT}" ]
}

@test "apply-jobs still waits for the one prerequisite Job annotated true when PREREQUISITE_JOB_WAIT is false" {
  export PREREQUISITE_JOB_WAIT=false
  stage_job prerequisite prerequisite-job-bad-one.yaml bad-one
  stage_job prerequisite prerequisite-job-bad-two.yaml bad-two
  JOB_WAIT=true stage_job prerequisite prerequisite-job-good.yaml good
  job_ends "${PREREQUISITE}/prerequisite-job-bad-one.yaml" Failed
  job_ends "${PREREQUISITE}/prerequisite-job-bad-two.yaml" Failed
  job_ends "${PREREQUISITE}/prerequisite-job-good.yaml" Complete 1
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  [ "$(<"${SENT}")" = "INFO: Waiting for 1 prerequisite job(s): good
INFO: The prerequisite jobs have finished: 1 waited for" ]
  run grep -- "^get -f ${PREREQUISITE}/prerequisite-job-bad" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "apply-jobs fails on a failed postdeploy Job annotated true even when POSTDEPLOY_JOB_WAIT is false" {
  export POSTDEPLOY_JOB_WAIT=false
  stage_job postdeploy postdeploy-job-bad.yaml bad
  JOB_WAIT=true stage_job postdeploy postdeploy-job-good.yaml good
  job_ends "${POSTDEPLOY}/postdeploy-job-bad.yaml" Failed
  job_ends "${POSTDEPLOY}/postdeploy-job-good.yaml" Failed
  run apply-jobs postdeploy
  [ "$status" -eq 61 ]
  [[ "$output" == *"ERROR: The postdeploy job good failed"* ]]
}

@test "apply-jobs does not wait for a Job annotated false even when its stage waits by default" {
  export PREREQUISITE_JOB_WAIT=true
  JOB_WAIT=false stage_job prerequisite prerequisite-job-bad.yaml bad
  job_ends "${PREREQUISITE}/prerequisite-job-bad.yaml" Failed
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
}

@test "apply-jobs takes each stage's switch for that stage only" {
  export PREREQUISITE_JOB_WAIT=false
  stage_job postdeploy postdeploy-job-announce.yaml announce
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Failed
  run apply-jobs postdeploy
  [ "$status" -eq 61 ]
  unset PREREQUISITE_JOB_WAIT
  export POSTDEPLOY_JOB_WAIT=false
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Failed
  run apply-jobs prerequisite
  [ "$status" -eq 61 ]
}

@test "apply-jobs keeps what it said for each stage apart" {
  stage_job prerequisite prerequisite-job-migrate.yaml migrate
  stage_job postdeploy postdeploy-job-announce.yaml announce
  job_ends "${PREREQUISITE}/prerequisite-job-migrate.yaml" Complete
  job_ends "${POSTDEPLOY}/postdeploy-job-announce.yaml" Complete
  run apply-jobs prerequisite
  [ "$status" -eq 0 ]
  run apply-jobs postdeploy
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/notify-once/prerequisite-jobs/last" ]
  [ -f "${TEST_RUN_BASE}/work/notify-once/postdeploy-jobs/last" ]
}
