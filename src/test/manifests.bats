#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for manifest preparation, validation, and application scripts.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  copy_fixture_manifests
  # Create work subdirs that deploy normally creates
  mkdir -p "${TEST_RUN_BASE}/work/manifests"
  mkdir -p "${TEST_RUN_BASE}/work/audit/kubectl"
  export ENVIRONMENT="test-env"
  export ENVIRONMENT_TYPE="env"
}

teardown() {
  teardown_test_dirs
}

# prepare-manifests tests

@test "prepare-manifests copies manifests to work directory" {
  run prepare-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/manifests/configmap.yaml" ]
  [ -f "${TEST_RUN_BASE}/work/manifests/deployment.yaml" ]
}

@test "prepare-manifests fails if work dir missing" {
  rm -rf "${TEST_RUN_BASE}/work/manifests"
  run prepare-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# validate-manifests tests

@test "validate-manifests runs dry-run for each file" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q "apply --dry-run=server --server-side --field-manager=kaptain/env/test-env -f" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests creates audit files" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run validate-manifests
  [ "$status" -eq 0 ]
  [ -d "${TEST_RUN_BASE}/work/audit/validation" ]
  local count
  count=$(find "${TEST_RUN_BASE}/work/audit/validation" -name "*.txt" | wc -l)
  [ "${count}" -gt 0 ]
}

@test "validate-manifests fails with no manifests" {
  run validate-manifests
  [ "$status" -eq 43 ]
  [[ "$output" == *"No manifest files"* ]]
}

@test "validate-manifests reports validation failures" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"--dry-run"* ]]; then
  echo "validation error" >&2
  exit 1
fi
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run validate-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Validation failed"* ]]
}

# validate-manifests tests for the sets split-manifests holds back
#
# A run-platform's own set and its seed-and-compare children are applied by
# hand later, so a deploy validates them while a cluster is there to do it.

write_set_manifest() {
  local dir="$1"
  local name="$2"
  mkdir -p "${dir}"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "${name}" > "${dir}/${name}.yaml"
}

@test "validate-manifests validates the run-platform's own set" {
  export ENVIRONMENT_TYPE="meta-env"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-f ${TEST_RUN_BASE}/work/self/own-thing.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests validates every seeded child set" {
  export ENVIRONMENT_TYPE="meta-env"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a" child-a
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-b" child-b
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-f ${TEST_RUN_BASE}/work/seed/run-env-a/child-a.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  grep -q -- "-f ${TEST_RUN_BASE}/work/seed/run-env-b/child-b.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests validates nested files within a seeded child set" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a/nested/deeper" buried
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-f ${TEST_RUN_BASE}/work/seed/run-env-a/nested/deeper/buried.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests ignores held-back sets on an environment deploy" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a" child-a
  run validate-manifests
  [ "$status" -eq 0 ]
  ! grep -q "work/self/" "${TEST_RUN_BASE}/work/k-commands.log"
  ! grep -q "work/seed/" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests passes with only a held-back set to validate" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  run validate-manifests
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validated 1 files"* ]]
}

@test "validate-manifests keeps audit files from different sets apart" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/manifests" same-name
  write_set_manifest "${TEST_RUN_BASE}/work/self" same-name
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a" same-name
  run validate-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/audit/validation/manifests_same-name.txt" ]
  [ -f "${TEST_RUN_BASE}/work/audit/validation/self_same-name.txt" ]
  [ -f "${TEST_RUN_BASE}/work/audit/validation/seed_run-env-a_same-name.txt" ]
}

@test "validate-manifests names the set when a held-back manifest fails" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a" child-a
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"--dry-run"* ]]; then
  echo "validation error" >&2
  exit 1
fi
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run validate-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"seed/run-env-a/child-a.yaml"* ]]
}

# apply-manifests tests

@test "apply-manifests calls k apply" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run apply-manifests
  [ "$status" -eq 0 ]
  grep -q "apply --server-side --field-manager=kaptain/env/test-env -R -f" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "apply-manifests creates audit log" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run apply-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply.log" ]
}

@test "apply-manifests notifies on success" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run apply-manifests
  [ "$status" -eq 0 ]
  [[ "$output" == *"Manifests applied"* ]]
}

@test "apply-manifests reports failure" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
if [[ "$*" == *"apply --server-side"* ]] && [[ "$*" != *"--dry-run"* ]]; then
  echo "apply error" >&2
  exit 1
fi
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  run apply-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Apply failed"* ]]
}
