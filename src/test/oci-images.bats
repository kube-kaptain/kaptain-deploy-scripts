#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for OCI image scanning and comparison scripts.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
}

teardown() {
  teardown_test_dirs
}

# oci-images tests

@test "oci-images requires label argument" {
  run oci-images
  [ "$status" -eq 42 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "oci-images creates output directory" {
  run oci-images "before"
  [ "$status" -eq 0 ]
  [ -d "${TEST_RUN_BASE}/work/oci-images" ]
}

@test "oci-images creates unsorted and sorted files" {
  run oci-images "before"
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/oci-images/oci-images-before-unsorted" ]
  [ -f "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted" ]
}

@test "oci-images queries multiple workload types" {
  run oci-images "after"
  [ "$status" -eq 0 ]
  # Should query deployments, statefulsets, daemonsets, jobs, cronjobs, replicasets, pods
  grep -q "deployments" "${TEST_RUN_BASE}/work/k-commands.log"
  grep -q "pods" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "oci-images extracts images from k output" {
  # Mock k to return some images
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"deployments"* ]]; then
  echo "nginx:1.25 redis:7.0"
elif [[ "$*" == *"pods"* ]]; then
  echo "busybox:latest"
fi
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run oci-images "test"
  [ "$status" -eq 0 ]
  grep -q "nginx:1.25" "${TEST_RUN_BASE}/work/oci-images/oci-images-test-sorted"
  grep -q "redis:7.0" "${TEST_RUN_BASE}/work/oci-images/oci-images-test-sorted"
  grep -q "busybox:latest" "${TEST_RUN_BASE}/work/oci-images/oci-images-test-sorted"
}

@test "oci-images deduplicates images in sorted output" {
  # Mock k to return duplicate images
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
echo "nginx:1.25 nginx:1.25 nginx:1.25"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run oci-images "test"
  [ "$status" -eq 0 ]
  local count
  count=$(grep -c "nginx:1.25" "${TEST_RUN_BASE}/work/oci-images/oci-images-test-sorted")
  [ "${count}" -eq 1 ]
}

# notify-oci-images-changed tests

@test "notify-oci-images-changed reports no changes when files identical" {
  mkdir -p "${TEST_RUN_BASE}/work/oci-images"
  echo -e "nginx:1.25\nredis:7.0" > "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted"
  echo -e "nginx:1.25\nredis:7.0" > "${TEST_RUN_BASE}/work/oci-images/oci-images-after-sorted"

  run notify-oci-images-changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"No OCI image changes"* ]]
  [[ "$output" == *"2 images"* ]]
}

@test "notify-oci-images-changed reports added images" {
  mkdir -p "${TEST_RUN_BASE}/work/oci-images"
  echo -e "nginx:1.25" > "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted"
  echo -e "nginx:1.25\nredis:7.0" > "${TEST_RUN_BASE}/work/oci-images/oci-images-after-sorted"

  run notify-oci-images-changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"image changes"* ]]
  [[ "$output" == *"+ redis:7.0"* ]]
}

@test "notify-oci-images-changed reports removed images" {
  mkdir -p "${TEST_RUN_BASE}/work/oci-images"
  echo -e "nginx:1.25\nredis:7.0" > "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted"
  echo -e "nginx:1.25" > "${TEST_RUN_BASE}/work/oci-images/oci-images-after-sorted"

  run notify-oci-images-changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"image changes"* ]]
  [[ "$output" == *"- redis:7.0"* ]]
}

@test "notify-oci-images-changed groups by registry" {
  mkdir -p "${TEST_RUN_BASE}/work/oci-images"
  echo "" > "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted"
  echo -e "docker.io/library/nginx:1.25\ngcr.io/project/app:v1" > "${TEST_RUN_BASE}/work/oci-images/oci-images-after-sorted"

  run notify-oci-images-changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker.io:"* ]]
  [[ "$output" == *"gcr.io:"* ]]
}

@test "notify-oci-images-changed handles bare image names as docker.io" {
  mkdir -p "${TEST_RUN_BASE}/work/oci-images"
  echo "" > "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted"
  echo "nginx:latest" > "${TEST_RUN_BASE}/work/oci-images/oci-images-after-sorted"

  run notify-oci-images-changed
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker.io:"* ]]
  [[ "$output" == *"nginx:latest"* ]]
}
