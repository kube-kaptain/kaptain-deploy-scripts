#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  install_mock_interruptible_sleep
  install_mock_validate_container
  install_mock_scan_images
  install_mock_notify_images_changed
  copy_fixture_manifests
  copy_fixture_templates
  copy_fixture_secrets
  # deploy runs the real validate-environment, which requires this ConfigMap
  write_cleanup_policy_configmap
  export ENVIRONMENT="run-test-env"
  export ENVIRONMENT_TYPE="env"
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

@test "deploy copies an environment's whole tree to the deploy stage and applies from there" {
  run deploy
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/manifests/configmap.yaml" ]
  cmp "${TEST_RUN_BASE}/work/manifests/configmap.yaml" "${TEST_RUN_BASE}/work/stages/deploy/configmap.yaml"
  cmp "${TEST_RUN_BASE}/work/manifests/secret.yaml" "${TEST_RUN_BASE}/work/stages/deploy/secret.yaml"
  grep -q -- "apply --server-side --field-manager=kaptain/env/run-test-env -R -f ${TEST_RUN_BASE}/work/stages/deploy/" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "deploy validates the complete tree, never the dirs split out of it" {
  run deploy
  [ "$status" -eq 0 ]
  grep -q -- "--dry-run=server .* -f ${TEST_RUN_BASE}/work/manifests/configmap.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  run grep -- "--dry-run=server .* -f ${TEST_RUN_BASE}/work/stages/" "${TEST_RUN_BASE}/work/k-commands.log"
  [ "$status" -eq 1 ]
}

@test "deploy splits a run-platform's own set and a seed-and-compare set, secrets assembled, out of a tree that stays complete and applies the rest" {
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  mkdir -p "${TEST_RUN_BASE}/manifests/run-platform-test"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: run-platform-own\n' \
    > "${TEST_RUN_BASE}/manifests/run-platform-test/configmap.yaml"
  mkdir -p "${TEST_RUN_BASE}/manifests/run-env-child"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: run-env-child-run-environment-seed-and-compare-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' \
    > "${TEST_RUN_BASE}/manifests/run-env-child/run-environment-seed-and-compare-marker.yaml"
  cp "${FIXTURES_DIR}/templates/secret.template.yaml" "${TEST_RUN_BASE}/manifests/run-env-child/"
  run deploy
  [ "$status" -eq 0 ]
  local tree="${TEST_RUN_BASE}/work/manifests"
  local seeded="${TEST_RUN_BASE}/work/seed/run-env-child"
  local staged="${TEST_RUN_BASE}/work/stages/deploy"
  # The seeded child and the run-platform's own set are copied out, assembled
  [ -f "${seeded}/secret.yaml" ]
  [[ "$(<"${seeded}/secret.yaml")" == *"super-secret-db-pass-123"* ]]
  [ -f "${TEST_RUN_BASE}/work/self/configmap.yaml" ]
  # The tree they came from is still complete, less the marker
  [ -f "${tree}/run-env-child/secret.yaml" ]
  [ -f "${tree}/run-platform-test/configmap.yaml" ]
  [ -f "${tree}/configmap.yaml" ]
  [ -z "$(find "${TEST_RUN_BASE}/work" -name 'run-environment-seed-and-compare-marker.yaml')" ]
  # Both are validated in the tree
  grep -q -- "--dry-run=server .* -f ${tree}/run-env-child/secret.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  grep -q -- "--dry-run=server .* -f ${tree}/run-platform-test/configmap.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  # Neither is in the stage that holds the rest
  [ -f "${staged}/configmap.yaml" ]
  [ ! -e "${staged}/run-env-child" ]
  [ ! -e "${staged}/run-platform-test" ]
}

# A run-platform's own set and its seeded children
#
# The mock k keeps a fake cluster, empty unless a test puts something in it, so
# by default a run-platform finds both its own set and its seeds missing.

# A run-platform with its own set and one seed-and-compare child, each a single
# ConfigMap, alongside the fixtures that make up the rest
run_platform_with_one_seed() {
  export ENVIRONMENT="run-platform-test"
  export ENVIRONMENT_TYPE="meta-env"
  mkdir -p "${TEST_RUN_BASE}/manifests/run-platform-test" "${TEST_RUN_BASE}/manifests/run-env-child"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: run-platform-own\n' \
    > "${TEST_RUN_BASE}/manifests/run-platform-test/configmap.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: run-env-child-config\n' \
    > "${TEST_RUN_BASE}/manifests/run-env-child/configmap.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: run-env-child-run-environment-seed-and-compare-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' \
    > "${TEST_RUN_BASE}/manifests/run-env-child/run-environment-seed-and-compare-marker.yaml"
  SELF_SET="${TEST_RUN_BASE}/work/self"
  SEED_SET="${TEST_RUN_BASE}/work/seed/run-env-child"
  STAGED="${TEST_RUN_BASE}/work/stages/deploy"
  K_LOG="${TEST_RUN_BASE}/work/k-commands.log"
}

# The run-platform's own deployer workload, mounting the named ConfigMap
write_own_workload() {
  local kind="$1"
  local file="$2"
  local config="$3"
  if [[ "${kind}" == "Deployment" ]]; then
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: run-platform-test\nspec:\n  template:\n    spec:\n      volumes:\n        - name: configmap\n          configMap:\n            name: %s\n' "${config}" > "${file}"
  else
    printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: run-platform-test\n  annotations:\n    keelson.pro/policy: patch\nspec:\n  suspend: true\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          volumes:\n            - name: configmap\n              configMap:\n                name: %s\n' "${config}" > "${file}"
  fi
}

line_of() {
  grep -n -- "$1" "${K_LOG}" | head -n 1 | cut -d: -f1
}

@test "deploy on a run-platform reapplies its own set first, then the rest, then its seeds" {
  run_platform_with_one_seed
  run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment complete"* ]]
  [ "$(grep -c -- "-R -f" "${K_LOG}")" -eq 3 ]
  local own rest seed
  own=$(line_of "-R -f ${SELF_SET}")
  rest=$(line_of "-R -f ${STAGED}/")
  seed=$(line_of "-R -f ${SEED_SET}")
  [ "${own}" -lt "${rest}" ]
  [ "${rest}" -lt "${seed}" ]
}

@test "deploy on a run-platform says in chat what it is reapplying and why" {
  run_platform_with_one_seed
  run deploy
  [ "$status" -eq 0 ]
  grep -qF "INFO: Our manifests differ from our resources (configmap.yaml missing). Reapplying, which will cause a restart. This check should pass after that." "${TEST_RUN_BASE}/work/notifications.log"
  grep -qF "INFO: The run-env-child manifests differ from its resources (configmap.yaml missing). Reapplying in full - this will cause a restart of the run-env-child environment control pod." "${TEST_RUN_BASE}/work/notifications.log"
}

@test "deploy on a run-platform leaves its own set and its seeds alone when they match the cluster" {
  run_platform_with_one_seed
  cluster_holds "${SELF_SET}/configmap.yaml" "${TEST_RUN_BASE}/manifests/run-platform-test/configmap.yaml"
  cluster_holds "${SEED_SET}/configmap.yaml" "${TEST_RUN_BASE}/manifests/run-env-child/configmap.yaml"
  run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment complete"* ]]
  [ "$(grep -c -- "-R -f" "${K_LOG}")" -eq 1 ]
  grep -q -- "-R -f ${STAGED}/" "${K_LOG}"
  run grep -F "differ from" "${TEST_RUN_BASE}/work/notifications.log"
  [ "$status" -eq 1 ]
}

@test "deploy on a run-platform in deployment mode stands down once it has changed its own pod template" {
  install_mock_interruptible_sleep_killer  # Killed while it waits to be replaced
  run_platform_with_one_seed
  export DEPLOY_MODE="deployment"
  write_own_workload Deployment "${TEST_RUN_BASE}/manifests/run-platform-test/deployment.yaml" run-platform-own-bbbbb
  write_own_workload Deployment "${TEST_RUN_BASE}/previous-deployment.yaml" run-platform-own-aaaaa
  cluster_holds "${SELF_SET}/deployment.yaml" "${TEST_RUN_BASE}/previous-deployment.yaml"
  run deploy
  [[ "$output" == *"Waiting up to 600s to be replaced by a pod running the reapplied manifests"* ]]
  [[ "$output" != *"Deployment complete"* ]]
  grep -q -- "-R -f ${SELF_SET}" "${K_LOG}"
  run grep -- "-R -f ${STAGED}/" "${K_LOG}"
  [ "$status" -eq 1 ]
  run grep -- "-R -f ${SEED_SET}" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "deploy on a run-platform fails when it reapplied itself and was never replaced" {
  # The wait for a replacement returns, then the sleep for inspection kills it
  interruptible_sleep() {
    local count_file="${RUN_BASE_PATH}/work/sleep-count"
    local count=0
    if [[ -f "${count_file}" ]]; then
      count=$(<"${count_file}")
    fi
    count=$((count + 1))
    echo "${count}" > "${count_file}"
    if [[ "${count}" -ge 2 ]]; then
      kill -KILL $$ 2>/dev/null
    fi
    return 0
  }
  export -f interruptible_sleep
  run_platform_with_one_seed
  export DEPLOY_MODE="deployment"
  export SELF_REPLACEMENT_WAIT="30"
  write_own_workload Deployment "${TEST_RUN_BASE}/manifests/run-platform-test/deployment.yaml" run-platform-own-bbbbb
  write_own_workload Deployment "${TEST_RUN_BASE}/previous-deployment.yaml" run-platform-own-aaaaa
  cluster_holds "${SELF_SET}/deployment.yaml" "${TEST_RUN_BASE}/previous-deployment.yaml"
  run deploy
  [[ "$output" == *"Reapplied our own manifests 30s ago and this pod has not been replaced"* ]]
  [[ "$output" == *"Deployment error during Waiting to be replaced"* ]]
  [[ "$output" == *"Exit code: 60"* ]]
  [[ "$output" == *"Sleeping forever for inspection"* ]]
  run grep -- "-R -f ${STAGED}/" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "deploy on a run-platform in job mode hands over to a new Job once it has changed its own CronJob" {
  run_platform_with_one_seed
  export HOSTNAME="run-platform-test-29384756-abcde"
  write_own_workload CronJob "${TEST_RUN_BASE}/manifests/run-platform-test/cronjob.yaml" run-platform-own-bbbbb
  write_own_workload CronJob "${TEST_RUN_BASE}/previous-cronjob.yaml" run-platform-own-aaaaa
  cluster_holds "${SELF_SET}/cronjob.yaml" "${TEST_RUN_BASE}/previous-cronjob.yaml"
  run deploy
  [ "$status" -eq 0 ]
  [[ "$output" != *"Deployment complete"* ]]
  grep -q -E -- "^create job --from=cronjob/run-platform-test run-platform-test-reapply-[0-9]+$" "${K_LOG}"
  run grep -- "-R -f ${STAGED}/" "${K_LOG}"
  [ "$status" -eq 1 ]
  run grep -- "-R -f ${SEED_SET}" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "deploy on a run-platform applies nothing else when its own set cannot be reapplied" {
  run_platform_with_one_seed
  cluster_fails apply
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Reapplying our own manifests failed"* ]]
  run grep -- "-R -f ${STAGED}/" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "deploy on an environment compares nothing with the cluster" {
  run deploy
  [ "$status" -eq 0 ]
  run grep -- "-o yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  [ "$status" -eq 1 ]
}

# Namespaces first, then each child's role binding in its own namespace

@test "deploy fails an environment whose manifests hold a Namespace, before asking the cluster anything" {
  mkdir -p "${TEST_RUN_BASE}/manifests/app-one"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: app-one-space\n' \
    > "${TEST_RUN_BASE}/manifests/app-one/namespace.yaml"
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Namespaces in a env deploy: 1"* ]]
  [[ "$output" == *"app-one/namespace.yaml"* ]]
  [ ! -f "${TEST_RUN_BASE}/work/k-commands.log" ]
}

@test "deploy on an environment never runs the namespaces step" {
  cat > "${TEST_MOCK_BIN}/apply-namespaces" << 'MOCK'
#!/usr/bin/env bash
echo "apply-namespaces was called" >> "${RUN_BASE_PATH}/work/unexpected.log"
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-namespaces"
  run deploy
  [ "$status" -eq 0 ]
  [ ! -f "${TEST_RUN_BASE}/work/unexpected.log" ]
}

@test "deploy on a run-platform dry-runs and applies its Namespaces before it validates the tree" {
  run_platform_with_one_seed
  mkdir -p "${TEST_RUN_BASE}/manifests/app-one"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: app-one-space\n' \
    > "${TEST_RUN_BASE}/manifests/app-one/namespace.yaml"
  run deploy
  [ "$status" -eq 0 ]
  local staged_namespaces="${TEST_RUN_BASE}/work/stages/namespaces"
  [ -f "${staged_namespaces}/app-one/namespace.yaml" ]
  [ ! -e "${STAGED}/app-one/namespace.yaml" ]
  local namespace_dry_run namespace_apply tree_dry_run own rest
  namespace_dry_run=$(line_of "--dry-run=server .* -f ${staged_namespaces}/app-one/namespace.yaml")
  namespace_apply=$(line_of "-R -f ${staged_namespaces}")
  tree_dry_run=$(line_of "--dry-run=server .* -f ${TEST_RUN_BASE}/work/manifests/")
  own=$(line_of "-R -f ${SELF_SET}")
  rest=$(line_of "-R -f ${STAGED}/")
  [ "${namespace_dry_run}" -lt "${namespace_apply}" ]
  [ "${namespace_apply}" -lt "${tree_dry_run}" ]
  [ "${tree_dry_run}" -lt "${own}" ]
  [ "${own}" -lt "${rest}" ]
}

@test "deploy on a run-platform applies its CRDs before its Namespaces" {
  run_platform_with_one_seed
  mkdir -p "${TEST_RUN_BASE}/manifests/app-one"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: app-one-space\n' \
    > "${TEST_RUN_BASE}/manifests/app-one/namespace.yaml"
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: widgets.example.com\n' \
    > "${TEST_RUN_BASE}/manifests/app-one/widget-crd.yaml"
  run deploy
  [ "$status" -eq 0 ]
  local crd_wait namespace_dry_run
  crd_wait=$(line_of "^get customresourcedefinition ")
  namespace_dry_run=$(line_of "--dry-run=server .* -f ${TEST_RUN_BASE}/work/stages/namespaces/")
  [ "${crd_wait}" -lt "${namespace_dry_run}" ]
}

# CRDs go in before the tree is validated

write_widget_crd() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: widgets.example.com\n' > "${file}"
}

@test "deploy on a run-platform dry-runs, applies and waits on its CRDs before it validates the tree" {
  run_platform_with_one_seed
  write_widget_crd "${TEST_RUN_BASE}/manifests/app-one/widget-crd.yaml"
  run deploy
  [ "$status" -eq 0 ]
  local crds="${TEST_RUN_BASE}/work/stages/crds"
  [ -f "${crds}/app-one/widget-crd.yaml" ]
  [ ! -e "${STAGED}/app-one/widget-crd.yaml" ]
  local crd_dry_run crd_apply crd_wait tree_dry_run own
  crd_dry_run=$(line_of "--dry-run=server .* -f ${crds}/app-one/widget-crd.yaml")
  crd_apply=$(line_of "-R -f ${crds}")
  crd_wait=$(line_of "^get customresourcedefinition widgets.example.com ")
  tree_dry_run=$(line_of "--dry-run=server .* -f ${TEST_RUN_BASE}/work/manifests/")
  own=$(line_of "-R -f ${SELF_SET}")
  [ "${crd_dry_run}" -lt "${crd_apply}" ]
  [ "${crd_apply}" -lt "${crd_wait}" ]
  [ "${crd_wait}" -lt "${tree_dry_run}" ]
  [ "${tree_dry_run}" -lt "${own}" ]
}

@test "deploy on a run-platform still validates its CRDs with the rest of the tree" {
  run_platform_with_one_seed
  write_widget_crd "${TEST_RUN_BASE}/manifests/app-one/widget-crd.yaml"
  run deploy
  [ "$status" -eq 0 ]
  grep -q -- "--dry-run=server .* -f ${TEST_RUN_BASE}/work/manifests/app-one/widget-crd.yaml" "${K_LOG}"
}

@test "deploy on a run-platform applies nothing and validates nothing else when a CRD is refused" {
  run_platform_with_one_seed
  install_mock_k_failing_dry_run
  write_widget_crd "${TEST_RUN_BASE}/manifests/app-one/widget-crd.yaml"
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRDs refused by the cluster: 1/1, none applied"* ]]
  run grep -- "-R -f" "${K_LOG}"
  [ "$status" -eq 1 ]
  run grep -- "-f ${TEST_RUN_BASE}/work/manifests/" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "deploy fails an environment whose manifests hold a CRD, before asking the cluster anything" {
  write_widget_crd "${TEST_RUN_BASE}/manifests/app-one/widget-crd.yaml"
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRDs in a env deploy: 1"* ]]
  [[ "$output" == *"app-one/widget-crd.yaml"* ]]
  [ ! -f "${TEST_RUN_BASE}/work/k-commands.log" ]
}

@test "deploy on an environment never runs the CRD step" {
  cat > "${TEST_MOCK_BIN}/apply-crds" << 'MOCK'
#!/usr/bin/env bash
echo "apply-crds was called" >> "${RUN_BASE_PATH}/work/unexpected.log"
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-crds"
  run deploy
  [ "$status" -eq 0 ]
  [ ! -f "${TEST_RUN_BASE}/work/unexpected.log" ]
}

# A run-platform whose one seeded child is namespace-only: it brings its own
# Namespace and a role binding in it
run_platform_with_a_namespace_only_seed() {
  run_platform_with_one_seed
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: run-env-child\n' \
    > "${TEST_RUN_BASE}/manifests/run-env-child/namespace.yaml"
  printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: run-env-child\n  namespace: run-env-child\n' \
    > "${TEST_RUN_BASE}/manifests/run-env-child/rolebinding.yaml"
  ORDER="${TEST_RUN_BASE}/work/role-binding-order.log"
  BINDING="${TEST_RUN_BASE}/work/child-role-binding/run-env-child/rolebinding.yaml"
}

@test "deploy on a run-platform applies a child's Namespace, then its role binding, then the rest, then its seed" {
  run_platform_with_a_namespace_only_seed
  install_child_role_binding_script run-env-child
  run deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment complete"* ]]
  grep -qxF "k-run-env-child-role-binding-only ${BINDING}" "${TEST_RUN_BASE}/work/role-binding-commands.log"
  # How many calls k had taken when the binding went in
  local namespaces binding_after rest seed
  namespaces=$(line_of "-R -f ${TEST_RUN_BASE}/work/stages/namespaces")
  binding_after=$(grep -v -- "--dry-run" "${ORDER}" | cut -d' ' -f1)
  rest=$(line_of "-R -f ${STAGED}/")
  seed=$(line_of "-R -f ${SEED_SET}")
  [ "${namespaces}" -lt "${binding_after}" ]
  [ "${binding_after}" -lt "${rest}" ]
  [ "${rest}" -lt "${seed}" ]
}

@test "deploy on a run-platform never sends a child's own-namespace role binding through k" {
  run_platform_with_a_namespace_only_seed
  install_child_role_binding_script run-env-child
  run deploy
  [ "$status" -eq 0 ]
  [ -f "${BINDING}" ]
  [ ! -e "${SEED_SET}/rolebinding.yaml" ]
  [ ! -e "${TEST_RUN_BASE}/work/manifests/run-env-child/rolebinding.yaml" ]
  run grep -- "rolebinding.yaml" "${K_LOG}"
  [ "$status" -eq 1 ]
}

@test "deploy on a run-platform dry-runs that role binding through the child's script once its Namespace is in, before its own set or anything else" {
  run_platform_with_a_namespace_only_seed
  install_child_role_binding_script run-env-child
  run deploy
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "${TEST_RUN_BASE}/work/role-binding-commands.log")" = "k-run-env-child-role-binding-only --dry-run ${BINDING}" ]
  local namespaces dry_run_after own
  namespaces=$(line_of "-R -f ${TEST_RUN_BASE}/work/stages/namespaces")
  dry_run_after=$(head -n 1 "${ORDER}" | cut -d' ' -f1)
  own=$(line_of "-R -f ${SELF_SET}")
  [ "${namespaces}" -le "${dry_run_after}" ]
  [ "${dry_run_after}" -lt "${own}" ]
}

@test "deploy on a run-platform applies nothing past its Namespaces when a child's role binding script is not in the image" {
  run_platform_with_a_namespace_only_seed
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"k-run-env-child-role-binding-only is not in this image"* ]]
  [ "$(grep -c -- "-R -f" "${K_LOG}")" -eq 1 ]
  grep -q -- "-R -f ${TEST_RUN_BASE}/work/stages/namespaces" "${K_LOG}"
}

@test "deploy on a run-platform applies nothing past its Namespaces when a child's role binding is refused" {
  run_platform_with_a_namespace_only_seed
  install_child_role_binding_script run-env-child
  child_role_binding_script_refuses run-env-child
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"The run-env-child role binding was refused"* ]]
  [ "$(grep -c -- "-R -f" "${K_LOG}")" -eq 1 ]
  grep -q -- "-R -f ${TEST_RUN_BASE}/work/stages/namespaces" "${K_LOG}"
}

@test "deploy fails an environment whose manifests hold a seed-and-compare marker" {
  mkdir -p "${TEST_RUN_BASE}/manifests/run-env-child"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: stray-marker\n  namespace: do-not-deploy-kaptain-seed-and-compare-marker-file-only\n' \
    > "${TEST_RUN_BASE}/manifests/run-env-child/run-environment-seed-and-compare-marker.yaml"
  run deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Seed-and-compare marker in a env deploy"* ]]
  ! grep -q 'apply --server-side' "${TEST_RUN_BASE}/work/k-commands.log" 2>/dev/null
}

@test "deploy calls k apply --dry-run=server --server-side for validation" {
  deploy
  [ -f "${TEST_RUN_BASE}/work/k-commands.log" ]
  grep -q "apply --dry-run=server --server-side --field-manager=kaptain/env/run-test-env -f" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "deploy calls k apply --server-side -R -f for actual apply" {
  deploy
  grep -q "apply --server-side --field-manager=kaptain/env/run-test-env -R -f" "${TEST_RUN_BASE}/work/k-commands.log"
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
  [[ "$output" == *"run-test-env"* ]]
}

@test "deploy logs version" {
  run deploy
  [[ "$output" == *"v1.0.0"* ]]
}

@test "deploy fails validation if manifests source dir missing" {
  rm -rf "${TEST_RUN_BASE}/manifests"
  run deploy
  [ "$status" -eq 44 ]
  [[ "$output" == *"Manifests directory not found"* ]]
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

@test "deploy calls scan-images before and after" {
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
  [[ "$output" == *"Starting run-test-env version v1.0.0"* ]]
}

@test "deploy notifies completion" {
  run deploy
  [[ "$output" == *"Deployment complete for run-test-env"* ]]
}

@test "deploy sends completion through notify-success" {
  deploy
  grep -q "^SUCCESS: Deployment complete for run-test-env version v1.0.0" "${TEST_RUN_BASE}/work/notifications.log"
}

@test "deploy sends an error through notify-failure, not notify-error" {
  cat > "${TEST_MOCK_BIN}/apply-manifests" << 'MOCK'
#!/usr/bin/env bash
exit 3
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-manifests"
  run deploy
  [ "$status" -ne 0 ]
  grep -q "^FAILURE: Deployment error during Applying manifests" "${TEST_RUN_BASE}/work/notifications.log"
  ! grep -q "^ERROR: Deployment error" "${TEST_RUN_BASE}/work/notifications.log"
  ! grep -q "^SUCCESS:" "${TEST_RUN_BASE}/work/notifications.log"
}

@test "deploy stops before its first message when a notify plugin validator blocks" {
  cat > "${TEST_MOCK_BIN}/validate-notify" << 'MOCK'
#!/usr/bin/env bash
exit 44
MOCK
  chmod +x "${TEST_MOCK_BIN}/validate-notify"
  run deploy
  [ "$status" -eq 44 ]
  ! grep -q "^INFO: \*Starting" "${TEST_RUN_BASE}/work/notifications.log"
  grep -q "^FAILURE: Deployment error during Pre Validation" "${TEST_RUN_BASE}/work/notifications.log"
  grep -q "Command: validate-notify" "${TEST_RUN_BASE}/work/notifications.log"
}

@test "deploy sets the chat thread key from environment and version" {
  cat > "${TEST_MOCK_BIN}/notify-info" << 'MOCK'
#!/usr/bin/env bash
echo "THREAD_KEY: ${NOTIFY_THREAD_KEY:-unset}" >> "${RUN_BASE_PATH}/work/notifications.log"
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-info"
  deploy
  [[ "$(head -1 "${TEST_RUN_BASE}/work/notifications.log")" == "THREAD_KEY: run-test-env-v1.0.0" ]]
}

@test "deploy keeps a chat thread key it was given" {
  cat > "${TEST_MOCK_BIN}/notify-info" << 'MOCK'
#!/usr/bin/env bash
echo "THREAD_KEY: ${NOTIFY_THREAD_KEY:-unset}" >> "${RUN_BASE_PATH}/work/notifications.log"
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-info"
  export NOTIFY_THREAD_KEY="given-key"
  deploy
  [[ "$(head -1 "${TEST_RUN_BASE}/work/notifications.log")" == "THREAD_KEY: given-key" ]]
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
  install_mock_interruptible_sleep_killer  # Need killer to break infinite loop
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
  install_mock_interruptible_sleep_killer  # Need killer to break infinite loop
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
