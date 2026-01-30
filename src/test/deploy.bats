#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  install_mock_sleep
  install_mock_validate_container
  install_mock_oci_images
  install_mock_notify_oci_images_changed
  copy_fixture_manifests
  copy_fixture_templates
  copy_fixture_secrets
  export ENVIRONMENT="test-env"
  export VERSION="v1.0.0"
  export DEPLOY_MODE="job"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
}

teardown() {
  teardown_test_dirs
}

@test "deploy completes successfully with valid fixtures" {
  run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Starting"* ]]
  [[ "$output" == *"Deployment complete"* ]]
}

@test "deploy copies manifests to work directory" {
  deploy
  [ -f "${TEST_RUN_BASE}/work/manifests/configmap.yaml" ]
  [ -f "${TEST_RUN_BASE}/work/manifests/deployment.yaml" ]
}

@test "deploy decrypts secrets to work directory" {
  deploy
  [ -f "${TEST_RUN_BASE}/work/decrypted/DbPassword" ]
  [ -f "${TEST_RUN_BASE}/work/decrypted/ApiKey" ]
}

@test "deploy decrypts secrets with correct values" {
  deploy
  db_pass=$(<"${TEST_RUN_BASE}/work/decrypted/DbPassword")
  api_key=$(<"${TEST_RUN_BASE}/work/decrypted/ApiKey")
  [ "${db_pass}" = "super-secret-db-pass-123" ]
  [ "${api_key}" = "sk-test-key-abc-456" ]
}

@test "deploy processes templates into yaml" {
  deploy
  [ -f "${TEST_RUN_BASE}/work/manifests/secret.yaml" ]
  [ ! -f "${TEST_RUN_BASE}/work/manifests/secret.template.yaml" ]
}

@test "deploy substitutes secrets into templates" {
  deploy
  result=$(<"${TEST_RUN_BASE}/work/manifests/secret.yaml")
  [[ "${result}" == *"super-secret-db-pass-123"* ]]
  [[ "${result}" == *"sk-test-key-abc-456"* ]]
}

@test "deploy calls k apply --dry-run=server for validation" {
  deploy
  [ -f "${TEST_RUN_BASE}/work/k-commands.log" ]
  grep -q "apply --dry-run=server" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "deploy calls k apply -f for actual apply" {
  deploy
  grep -q "apply -f" "${TEST_RUN_BASE}/work/k-commands.log"
  # Should have both dry-run and real apply
  local count
  count=$(grep -c "apply" "${TEST_RUN_BASE}/work/k-commands.log")
  [ "${count}" -ge 2 ]
}

@test "deploy creates audit directory with logs" {
  deploy
  [ -d "${TEST_RUN_BASE}/work/audit" ]
  [ -d "${TEST_RUN_BASE}/work/audit/validation" ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply.log" ]
}

@test "deploy logs environment name" {
  run deploy
  [[ "$output" == *"test-env"* ]]
}

@test "deploy logs version" {
  run deploy
  [[ "$output" == *"v1.0.0"* ]]
}

@test "deploy fails if manifests source dir missing" {
  rm -rf "${TEST_RUN_BASE}/manifests"
  run deploy
  [ "$status" -eq 1 ]
}

@test "deploy succeeds with no secrets" {
  rm -rf "${TEST_RUN_BASE}/secrets/"*
  run deploy
  [ "$status" -eq 0 ]
}

@test "deploy succeeds with no templates" {
  # Remove template files from source manifests
  rm -f "${TEST_RUN_BASE}/manifests/"*.template.yaml
  run deploy
  [ "$status" -eq 0 ]
}

@test "deploy calls oci-images before and after" {
  deploy
  [ -f "${TEST_RUN_BASE}/work/oci-images/oci-images-before-sorted" ]
  [ -f "${TEST_RUN_BASE}/work/oci-images/oci-images-after-sorted" ]
}

@test "deploy outputs elapsed time" {
  run deploy
  [[ "$output" == *"seconds"* ]]
}

@test "deploy notifies start with timestamp" {
  run deploy
  [[ "$output" == *"Starting test-env version v1.0.0"* ]]
}

@test "deploy notifies completion" {
  run deploy
  [[ "$output" == *"Deployment complete for test-env"* ]]
}

# Mode-specific behavior tests

@test "deploy in job mode sleeps POST_DEPLOY_SLEEP_SUCCESS before exit" {
  export DEPLOY_MODE="job"
  run deploy
  [[ "$output" == *"sleeping 600s before exit"* ]]
}

@test "deploy in job mode uses custom POST_DEPLOY_SLEEP_SUCCESS" {
  export DEPLOY_MODE="job"
  export POST_DEPLOY_SLEEP_SUCCESS="120"
  run deploy
  [[ "$output" == *"sleeping 120s before exit"* ]]
}

@test "deploy in deployment mode sleeps forever" {
  install_mock_sleep_killer  # Need killer to break infinite loop
  export DEPLOY_MODE="deployment"
  run deploy
  [[ "$output" == *"sleeping forever"* ]]
}

@test "deploy in job mode on error sleeps POST_DEPLOY_SLEEP_FAILURE before exit" {
  export DEPLOY_MODE="job"
  # Make apply-manifests fail to trigger error handler
  cat > "${TEST_MOCK_BIN}/apply-manifests" << 'MOCK'
#!/usr/bin/env bash
exit 3
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-manifests"
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Sleeping 86400s before exit"* ]]
}

@test "deploy in job mode on error uses custom POST_DEPLOY_SLEEP_FAILURE" {
  export DEPLOY_MODE="job"
  export POST_DEPLOY_SLEEP_FAILURE="300"
  # Make apply-manifests fail to trigger error handler
  cat > "${TEST_MOCK_BIN}/apply-manifests" << 'MOCK'
#!/usr/bin/env bash
exit 3
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-manifests"
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Sleeping 300s before exit"* ]]
}

@test "deploy in deployment mode on error sleeps forever" {
  install_mock_sleep_killer  # Need killer to break infinite loop
  export DEPLOY_MODE="deployment"
  # Make apply-manifests fail to trigger error handler
  cat > "${TEST_MOCK_BIN}/apply-manifests" << 'MOCK'
#!/usr/bin/env bash
exit 3
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-manifests"
  run deploy
  [[ "$output" == *"Sleeping forever for inspection"* ]]
}
