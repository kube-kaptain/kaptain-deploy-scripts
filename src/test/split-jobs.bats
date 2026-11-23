#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for split-jobs: prerequisite Jobs, with what they need, and postdeploy
# Jobs each leave the deploy stage for a stage of their own.

load test_helper

setup() {
  setup_test_dirs
  install_mock_notify
  DEPLOY="${TEST_RUN_BASE}/work/stages/deploy"
  PREREQUISITE="${TEST_RUN_BASE}/work/stages/prerequisite"
  POSTDEPLOY="${TEST_RUN_BASE}/work/stages/postdeploy"
  mkdir -p "${DEPLOY}"
}

teardown() {
  teardown_test_dirs
}

# A plain resource in the deploy stage: kind, name, where
resource() {
  local file="${DEPLOY}/$3"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: %s\nmetadata:\n  name: %s\n' "$1" "$2" > "${file}"
}

# A Job in the deploy stage that needs nothing, or only the one ConfigMap named
job() {
  local file="${DEPLOY}/$1"
  local config="${2:-}"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: %s\nspec:\n  template:\n    spec:\n      containers:\n        - name: main\n          image: example.org/thing:1.0.0\n' \
    "$(basename "$1" .yaml)" > "${file}"
  if [[ -n "${config}" ]]; then
    printf '          envFrom:\n            - configMapRef:\n                name: %s\n' "${config}" >> "${file}"
  fi
}

# A Job that refers to something in every way a pod template can
job_needing_everything() {
  local file="${DEPLOY}/$1"
  mkdir -p "$(dirname "${file}")"
  cat > "${file}" << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate
spec:
  template:
    spec:
      serviceAccountName: migrator
      imagePullSecrets:
        - name: registry-login
      initContainers:
        - name: wait
          image: example.org/wait:1.0.0
          env:
            - name: TOKEN
              valueFrom:
                secretKeyRef:
                  name: init-token
                  key: token
      containers:
        - name: migrate
          image: example.org/migrate:1.0.0
          env:
            - name: PLAIN
              value: plain
            - name: LEVEL
              valueFrom:
                configMapKeyRef:
                  name: env-config
                  key: level
          envFrom:
            - configMapRef:
                name: envfrom-config
            - secretRef:
                name: envfrom-secret
      volumes:
        - name: scripts
          configMap:
            name: mounted-config
        - name: credentials
          secret:
            secretName: mounted-secret
        - name: data
          persistentVolumeClaim:
            claimName: migrate-data
        - name: combined
          projected:
            sources:
              - configMap:
                  name: projected-config
              - secret:
                  name: projected-secret
        - name: scratch
          emptyDir: {}
EOF
}

# A RoleBinding in the deploy stage: its name, the account it names, the Role
# it points to, where
role_binding() {
  local file="${DEPLOY}/$4"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: %s\nsubjects:\n  - kind: ServiceAccount\n    name: %s\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: Role\n  name: %s\n' \
    "$1" "$2" "$3" > "${file}"
}

# Which Jobs go where

@test "split-jobs moves a prerequisite job to its own stage, keeping its path and file name" {
  job api/prerequisite-job-migrate.yaml
  resource Service api api/service.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${PREREQUISITE}/api/prerequisite-job-migrate.yaml" ]
  [ ! -e "${DEPLOY}/api/prerequisite-job-migrate.yaml" ]
  [ -f "${DEPLOY}/api/service.yaml" ]
}

@test "split-jobs moves a postdeploy job to its own stage, keeping its path and file name" {
  job api/postdeploy-job-announce.yaml
  resource Service api api/service.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${POSTDEPLOY}/api/postdeploy-job-announce.yaml" ]
  [ ! -e "${DEPLOY}/api/postdeploy-job-announce.yaml" ]
  [ -f "${DEPLOY}/api/service.yaml" ]
}

@test "split-jobs goes by the file name: with or without a suffix, anywhere in the stage, and nothing else" {
  job prerequisite-job.yaml
  job deep/er/prerequisite-job-seed.yaml
  job postdeploy-job.yaml
  job api/job-prerequisite.yaml
  job api/job.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${PREREQUISITE}/prerequisite-job.yaml" ]
  [ -f "${PREREQUISITE}/deep/er/prerequisite-job-seed.yaml" ]
  [ -f "${POSTDEPLOY}/postdeploy-job.yaml" ]
  [ -f "${DEPLOY}/api/job-prerequisite.yaml" ]
  [ -f "${DEPLOY}/api/job.yaml" ]
}

@test "split-jobs does nothing, and makes neither stage, when there is no such job" {
  job api/job.yaml
  resource Service api api/service.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ ! -e "${PREREQUISITE}" ]
  [ ! -e "${POSTDEPLOY}" ]
  grep -qF "Job stages: 0 prerequisite job(s) with 0 of what they need, 0 postdeploy job(s)" "${TEST_RUN_BASE}/work/container.log"
}

# What a prerequisite job takes with it

@test "split-jobs takes everything a prerequisite job's pod template names, and nothing it does not" {
  job_needing_everything api/prerequisite-job-migrate.yaml
  resource ServiceAccount migrator api/serviceaccount.yaml
  resource Secret registry-login pull/secret-registry-login.yaml
  resource Secret init-token api/secret-init-token.yaml
  resource ConfigMap env-config api/configmap-env.yaml
  resource ConfigMap envfrom-config api/configmap-envfrom.yaml
  resource Secret envfrom-secret api/secret-envfrom.yaml
  resource ConfigMap mounted-config api/configmap-mounted.yaml
  resource Secret mounted-secret api/secret-mounted.yaml
  resource PersistentVolumeClaim migrate-data api/persistentvolumeclaim.yaml
  resource ConfigMap projected-config api/configmap-projected.yaml
  resource Secret projected-secret api/secret-projected.yaml
  resource ConfigMap unrelated api/configmap-unrelated.yaml
  resource Service api api/service.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  for taken in api/serviceaccount.yaml pull/secret-registry-login.yaml api/secret-init-token.yaml \
    api/configmap-env.yaml api/configmap-envfrom.yaml api/secret-envfrom.yaml api/configmap-mounted.yaml \
    api/secret-mounted.yaml api/persistentvolumeclaim.yaml api/configmap-projected.yaml api/secret-projected.yaml; do
    [ -f "${PREREQUISITE}/${taken}" ]
    [ ! -e "${DEPLOY}/${taken}" ]
  done
  [ -f "${DEPLOY}/api/configmap-unrelated.yaml" ]
  [ -f "${DEPLOY}/api/service.yaml" ]
  grep -qF "Job stages: 1 prerequisite job(s) with 11 of what they need, 0 postdeploy job(s)" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-jobs takes each RoleBinding naming the job's account and the Role it points to, and leaves any other" {
  job_needing_everything api/prerequisite-job-migrate.yaml
  resource ServiceAccount migrator api/serviceaccount.yaml
  role_binding migrator-binding migrator migrator-role api/rolebinding-migrator.yaml
  resource Role migrator-role api/role-migrator.yaml
  role_binding other-binding someone-else other-role api/rolebinding-other.yaml
  resource Role other-role api/role-other.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${PREREQUISITE}/api/rolebinding-migrator.yaml" ]
  [ -f "${PREREQUISITE}/api/role-migrator.yaml" ]
  [ -f "${DEPLOY}/api/rolebinding-other.yaml" ]
  [ -f "${DEPLOY}/api/role-other.yaml" ]
}

@test "split-jobs tells a ConfigMap from a Secret of the same name" {
  job prerequisite-job-migrate.yaml shared
  resource ConfigMap shared configmap-shared.yaml
  resource Secret shared secret-shared.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${PREREQUISITE}/configmap-shared.yaml" ]
  [ -f "${DEPLOY}/secret-shared.yaml" ]
}

@test "split-jobs logs what a prerequisite job needs that is not in the manifests, and carries on" {
  job prerequisite-job-migrate.yaml already-in-the-cluster
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${PREREQUISITE}/prerequisite-job-migrate.yaml" ]
  grep -qF "ConfigMap already-in-the-cluster is not in the manifests, expecting it to be in the cluster already" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-jobs moves what two prerequisite jobs both need once" {
  job prerequisite-job-first.yaml shared
  job prerequisite-job-second.yaml shared
  resource ConfigMap shared configmap-shared.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${PREREQUISITE}/prerequisite-job-first.yaml" ]
  [ -f "${PREREQUISITE}/prerequisite-job-second.yaml" ]
  [ -f "${PREREQUISITE}/configmap-shared.yaml" ]
  grep -qF "Job stages: 2 prerequisite job(s) with 1 of what they need, 0 postdeploy job(s)" "${TEST_RUN_BASE}/work/container.log"
}

@test "split-jobs leaves what a postdeploy job needs in the deploy stage" {
  job postdeploy-job-announce.yaml announce-config
  resource ConfigMap announce-config configmap-announce.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  [ -f "${POSTDEPLOY}/postdeploy-job-announce.yaml" ]
  [ -f "${DEPLOY}/configmap-announce.yaml" ]
  [ "$(find "${POSTDEPLOY}" -type f | wc -l)" -eq 1 ]
}

# Refusing

@test "split-jobs fails on a file named as a prerequisite job that is not a Job" {
  resource ConfigMap sneaky api/prerequisite-job-sneaky.yaml
  run split-jobs
  [ "$status" -eq 51 ]
  [[ "$output" == *"Named as a prerequisite job but it is not a Job (ConfigMap): api/prerequisite-job-sneaky.yaml"* ]]
}

@test "split-jobs fails on a file named as a postdeploy job that is not a Job" {
  resource ConfigMap sneaky postdeploy-job-sneaky.yaml
  run split-jobs
  [ "$status" -eq 51 ]
  [[ "$output" == *"Named as a postdeploy job but it is not a Job (ConfigMap): postdeploy-job-sneaky.yaml"* ]]
}

@test "split-jobs refuses to run a second time in the same container" {
  job prerequisite-job-migrate.yaml
  run split-jobs
  [ "$status" -eq 0 ]
  run split-jobs
  [ "$status" -ne 0 ]
  [[ "$output" == *"The job stages have already been split in this container, refusing to do it again"* ]]
}

@test "split-jobs fails when split-manifests has not run" {
  rm -rf "${DEPLOY}"
  run split-jobs
  [ "$status" -ne 0 ]
  [[ "$output" == *"The deploy stage does not exist, split-manifests has to run first"* ]]
}

@test "split-jobs has nothing to do when the deploy stage is empty" {
  run split-jobs
  [ "$status" -eq 0 ]
  [ ! -e "${PREREQUISITE}" ]
  [ ! -e "${POSTDEPLOY}" ]
}
