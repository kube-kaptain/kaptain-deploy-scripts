#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for keep-newer-image-tags: a reapply of a child's set never rolls the
# child's image back.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  SET="${TEST_RUN_BASE}/work/seed/run-omg"
  LIVE="${TEST_RUN_BASE}/live"
  mkdir -p "${SET}" "${LIVE}"
}

teardown() {
  teardown_test_dirs
}

write_deployment() {
  local file="$1"
  local image="$2"
  local init_image="${3:-}"
  {
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: run-omg\nspec:\n  template:\n    spec:\n'
    if [[ -n "${init_image}" ]]; then
      printf '      initContainers:\n        - name: prepare\n          image: %s\n' "${init_image}"
    fi
    printf '      containers:\n        - name: default-app\n          image: %s\n' "${image}"
  } > "${file}"
}

write_cronjob() {
  local file="$1"
  local image="$2"
  printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: run-omg\nspec:\n  suspend: true\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          containers:\n            - name: default-app\n              image: %s\n' "${image}" > "${file}"
}

image_in() {
  yq '.spec.template.spec.containers[0].image' "$1"
}

@test "keep-newer-image-tags needs exactly one argument" {
  run keep-newer-image-tags
  [ "$status" -eq 42 ]
}

@test "keep-newer-image-tags keeps a newer live tag" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.7" ]
  grep -qF "kept the newer live tag 1.0.7 over 1.0.4" "${TEST_RUN_BASE}/work/container.log"
}

@test "keep-newer-image-tags leaves a tag that is already newer than the live one" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.9
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.9" ]
}

@test "keep-newer-image-tags leaves a tag that matches the live one" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.7" ]
}

@test "keep-newer-image-tags orders tags as versions, not as text" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.9
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.10
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.10" ]
}

@test "keep-newer-image-tags leaves the set as written when the workload is not in the cluster" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.4" ]
}

@test "keep-newer-image-tags leaves an image from a different registry" {
  write_deployment "${SET}/deployment.yaml" registry.example.com/org/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "registry.example.com/org/run/run-omg:1.0.4" ]
}

@test "keep-newer-image-tags leaves an image from a different namespace" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/other/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/other/run/run-omg:1.0.4" ]
}

@test "keep-newer-image-tags leaves an image with a different name" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg-two:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg-two:1.0.4" ]
}

@test "keep-newer-image-tags leaves an image pinned by digest" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg@sha256:0123abcd
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg@sha256:0123abcd" ]
}

@test "keep-newer-image-tags leaves an untagged image behind a registry port" {
  write_deployment "${SET}/deployment.yaml" registry.example.com:5000/run-omg
  write_deployment "${LIVE}/deployment.yaml" registry.example.com:5000/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "registry.example.com:5000/run-omg" ]
}

@test "keep-newer-image-tags handles each container's image on its own" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4 ghcr.io/org/tools/prepare:2.0.0
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7 ghcr.io/org/tools/prepare:1.9.0
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${SET}/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.7" ]
  [ "$(yq '.spec.template.spec.initContainers[0].image' "${SET}/deployment.yaml")" = "ghcr.io/org/tools/prepare:2.0.0" ]
}

@test "keep-newer-image-tags reaches the image inside a CronJob's job template" {
  write_cronjob "${SET}/cronjob.yaml" ghcr.io/org/run/run-omg:1.0.4
  write_cronjob "${LIVE}/cronjob.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/cronjob.yaml" "${LIVE}/cronjob.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' "${SET}/cronjob.yaml")" = "ghcr.io/org/run/run-omg:1.0.7" ]
}

@test "keep-newer-image-tags does not ask the cluster about a file with no container images" {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\ndata:\n  image: "ghcr.io/org/thing:1"\n' > "${SET}/configmap.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ ! -f "${TEST_RUN_BASE}/work/k-commands.log" ]
  grep -qF 'image: "ghcr.io/org/thing:1"' "${SET}/configmap.yaml"
}

@test "keep-newer-image-tags leaves work/manifests alone" {
  mkdir -p "${TEST_RUN_BASE}/work/manifests/run-omg"
  write_deployment "${TEST_RUN_BASE}/work/manifests/run-omg/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  write_deployment "${LIVE}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.7
  cluster_holds "${SET}/deployment.yaml" "${LIVE}/deployment.yaml"
  run keep-newer-image-tags "${SET}"
  [ "$status" -eq 0 ]
  [ "$(image_in "${TEST_RUN_BASE}/work/manifests/run-omg/deployment.yaml")" = "ghcr.io/org/run/run-omg:1.0.4" ]
}

@test "keep-newer-image-tags fails when the live object cannot be read for a reason other than not being there" {
  write_deployment "${SET}/deployment.yaml" ghcr.io/org/run/run-omg:1.0.4
  cluster_fails get
  run keep-newer-image-tags "${SET}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not read the live object for seed/run-omg/deployment.yaml"* ]]
}
