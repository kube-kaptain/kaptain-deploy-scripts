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
  install_mock_k_failing_dry_run

  run validate-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"Validation failed"* ]]
}

# validate-manifests: only a run-platform may bring CRDs or Namespaces
#
# split-manifests puts every CRD it finds in the crds stage and every Namespace
# in the namespaces stage, so on an environment deploy both stages have to be
# empty. The build is meant to refuse them first; this is the second lock.

write_staged_crd() {
  local relative="$1"
  local file="${TEST_RUN_BASE}/work/stages/crds/${relative}"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nmetadata:\n  name: widgets.example.com\n' > "${file}"
}

write_staged_namespace() {
  local relative="$1"
  local file="${TEST_RUN_BASE}/work/stages/namespaces/${relative}"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: somewhere\n' > "${file}"
}

@test "validate-manifests fails an environment deploy that holds a Namespace" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_staged_namespace app-one/namespace.yaml
  run validate-manifests
  [ "$status" -eq 52 ]
  [[ "$output" == *"Namespaces in a env deploy: 1"* ]]
  [[ "$output" == *"Namespaces belong to the cluster, not to an environment. Only the run-platform manages them. Move them out of test-env and into the run-platform:"* ]]
  [[ "$output" == *"  - app-one/namespace.yaml"* ]]
}

@test "validate-manifests lists every Namespace an environment deploy holds" {
  write_staged_namespace app-one/namespace.yaml
  write_staged_namespace app-two/nested/another.yaml
  write_staged_namespace shared-namespace.yaml
  run validate-manifests
  [ "$status" -eq 52 ]
  [[ "$output" == *"Namespaces in a env deploy: 3"* ]]
  [[ "$output" == *"  - app-one/namespace.yaml"* ]]
  [[ "$output" == *"  - app-two/nested/another.yaml"* ]]
  [[ "$output" == *"  - shared-namespace.yaml"* ]]
}

@test "validate-manifests refuses an environment's Namespaces before asking the cluster anything" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_staged_namespace app-one/namespace.yaml
  run validate-manifests
  [ "$status" -eq 52 ]
  [ ! -f "${TEST_RUN_BASE}/work/k-commands.log" ]
}

@test "validate-manifests lets a run-platform deploy hold Namespaces" {
  export ENVIRONMENT_TYPE="meta-env"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_staged_namespace run-env-a/namespace.yaml
  run validate-manifests
  [ "$status" -eq 0 ]
}

@test "validate-manifests passes an environment deploy whose namespaces and crds stages are empty" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  mkdir -p "${TEST_RUN_BASE}/work/stages/namespaces" "${TEST_RUN_BASE}/work/stages/crds"
  run validate-manifests
  [ "$status" -eq 0 ]
}

@test "validate-manifests fails an environment deploy that holds a CRD" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_staged_crd app-one/widget-crd.yaml
  run validate-manifests
  [ "$status" -eq 52 ]
  [[ "$output" == *"CRDs in a env deploy: 1"* ]]
  [[ "$output" == *"CRDs belong to the cluster, not to an environment. Only the run-platform manages them. Move them out of test-env and into the run-platform:"* ]]
  [[ "$output" == *"  - app-one/widget-crd.yaml"* ]]
  [ ! -f "${TEST_RUN_BASE}/work/k-commands.log" ]
}

@test "validate-manifests reports an environment's CRDs and its Namespaces together" {
  write_staged_crd app-one/widget-crd.yaml
  write_staged_namespace app-one/namespace.yaml
  run validate-manifests
  [ "$status" -eq 52 ]
  [[ "$output" == *"CRDs in a env deploy: 1"* ]]
  [[ "$output" == *"Namespaces in a env deploy: 1"* ]]
}

@test "validate-manifests lets a run-platform deploy hold CRDs" {
  export ENVIRONMENT_TYPE="meta-env"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_staged_crd app-one/widget-crd.yaml
  run validate-manifests
  [ "$status" -eq 0 ]
}

# validate-manifests kind pre-check tests
#
# An unresolvable kind makes kubectl throw away its discovery cache and refetch
# the full OpenAPI document, per file. One discovery read per distinct
# apiVersion up front instead, and nothing reaches the dry-run until it passes.

write_manifest() {
  local file="$1"
  local api_version="$2"
  local kind="$3"
  mkdir -p "$(dirname "${file}")"
  printf 'apiVersion: %s\nkind: %s\nmetadata:\n  name: %s\n' \
    "${api_version}" "${kind}" "$(basename "${file}" .yaml)" > "${file}"
}

write_widget_crd() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  cat > "${file}" << 'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.com
spec:
  group: example.com
  scope: Namespaced
  names:
    kind: Widget
    plural: widgets
  versions:
    - name: v1
      served: true
      storage: true
    - name: v2
      served: true
      storage: false
YAML
}

@test "validate-manifests fails before any dry-run when a group is not served" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/widget.yaml" example.com/v1 Widget
  run validate-manifests
  [ "$status" -eq 50 ]
  [[ "$output" == *"manifests/widget.yaml: example.com/v1 Widget"* ]]
  ! grep -q -- "--dry-run" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests fails on a kind missing from a group that is served" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/nonsense.yaml" v1 Nonsense
  run validate-manifests
  [ "$status" -eq 50 ]
  [[ "$output" == *"manifests/nonsense.yaml: v1 Nonsense"* ]]
}

@test "validate-manifests lists every unserved kind at once" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/widget.yaml" example.com/v1 Widget
  write_manifest "${TEST_RUN_BASE}/work/manifests/gadget.yaml" other.example.com/v1 Gadget
  run validate-manifests
  [ "$status" -eq 50 ]
  [[ "$output" == *"Kinds not served by this cluster: 2"* ]]
  [[ "$output" == *"manifests/gadget.yaml: other.example.com/v1 Gadget"* ]]
  [[ "$output" == *"manifests/widget.yaml: example.com/v1 Widget"* ]]
}

@test "validate-manifests passes a kind the cluster serves" {
  serve_discovery /apis/example.com/v1 Widget
  write_manifest "${TEST_RUN_BASE}/work/manifests/widget.yaml" example.com/v1 Widget
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "--dry-run=server .* -f ${TEST_RUN_BASE}/work/manifests/widget.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests accepts a kind the set installs itself as a CRD" {
  write_widget_crd "${TEST_RUN_BASE}/work/manifests/widget-crd.yaml"
  write_manifest "${TEST_RUN_BASE}/work/manifests/widget.yaml" example.com/v1 Widget
  write_manifest "${TEST_RUN_BASE}/work/manifests/widget-two.yaml" example.com/v2 Widget
  run validate-manifests
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validated 3 files"* ]]
}

@test "validate-manifests does not ask about an apiVersion its own CRD defines" {
  write_widget_crd "${TEST_RUN_BASE}/work/manifests/widget-crd.yaml"
  write_manifest "${TEST_RUN_BASE}/work/manifests/widget.yaml" example.com/v1 Widget
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "get --raw /apis/apiextensions.k8s.io/v1" "${TEST_RUN_BASE}/work/k-commands.log"
  ! grep -q -- "get --raw /apis/example.com/v1" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests asks the cluster once per distinct apiVersion" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_manifest "${TEST_RUN_BASE}/work/manifests/second-map.yaml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/manifests/nested/third-map.yaml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/manifests/second-deployment.yaml" apps/v1 Deployment
  run validate-manifests
  [ "$status" -eq 0 ]
  local calls
  calls=$(grep -c -- "get --raw" "${TEST_RUN_BASE}/work/k-commands.log")
  [ "${calls}" -eq 2 ]
}

@test "validate-manifests pre-checks a run-platform's child sets within the tree" {
  export ENVIRONMENT_TYPE="meta-env"
  write_manifest "${TEST_RUN_BASE}/work/manifests/run-platform-own/own-thing.yaml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/manifests/run-env-a/widget.yaml" example.com/v1 Widget
  run validate-manifests
  [ "$status" -eq 50 ]
  [[ "$output" == *"manifests/run-env-a/widget.yaml: example.com/v1 Widget"* ]]
}

@test "validate-manifests leaves a document with no kind to the dry-run" {
  printf 'apiVersion: v1\nmetadata:\n  name: kindless\n' > "${TEST_RUN_BASE}/work/manifests/kindless.yaml"
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-f ${TEST_RUN_BASE}/work/manifests/kindless.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

# validate-manifests set shape tests
#
# The first check of all: one spelling of the extension, one document per file.
# kubectl reads .yaml, .yml and .json from a directory and only in lowercase,
# so anything else is either applied unvalidated or silently not applied.

@test "validate-manifests rejects a .yml file" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_manifest "${TEST_RUN_BASE}/work/manifests/sneaky.yml" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/sneaky.yml"* ]]
}

@test "validate-manifests rejects a .json file" {
  printf '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"j"}}\n' \
    > "${TEST_RUN_BASE}/work/manifests/sneaky.json"
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/sneaky.json"* ]]
}

@test "validate-manifests rejects an uppercase .YAML that kubectl would skip" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/shouty.YAML" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/shouty.YAML"* ]]
}

@test "validate-manifests rejects a disabled manifest left in the set" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/old.yaml.disabled" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/old.yaml.disabled"* ]]
}

@test "validate-manifests lists every rejected file at once" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/one.yml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/manifests/nested/two.yml" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"not .yaml: 2"* ]]
  [[ "$output" == *"manifests/nested/two.yml"* ]]
  [[ "$output" == *"manifests/one.yml"* ]]
}

@test "validate-manifests rejects the set before asking the cluster anything" {
  write_manifest "${TEST_RUN_BASE}/work/manifests/sneaky.yml" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [ ! -f "${TEST_RUN_BASE}/work/k-commands.log" ]
}

@test "validate-manifests ignores dot files and dot directories" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  printf 'finder\n' > "${TEST_RUN_BASE}/work/manifests/.DS_Store"
  mkdir -p "${TEST_RUN_BASE}/work/manifests/.hidden"
  printf 'notes\n' > "${TEST_RUN_BASE}/work/manifests/.hidden/scratch.txt"
  run validate-manifests
  [ "$status" -eq 0 ]
}

@test "validate-manifests rejects a README left in the set" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  printf 'notes\n' > "${TEST_RUN_BASE}/work/manifests/README.md"
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/README.md"* ]]
}

@test "validate-manifests rejects a multi-document file" {
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: first\n'
    printf -- '---\n'
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: second\n'
  } > "${TEST_RUN_BASE}/work/manifests/multi.yaml"
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/multi.yaml: 2 documents"* ]]
}

@test "validate-manifests rejects a trailing separator as a second document" {
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: only\n'
    printf -- '---\n'
  } > "${TEST_RUN_BASE}/work/manifests/trailing-separator.yaml"
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/trailing-separator.yaml: 2 documents"* ]]
}

@test "validate-manifests allows a lone leading separator" {
  {
    printf -- '---\n'
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: only\n'
  } > "${TEST_RUN_BASE}/work/manifests/leading-separator.yaml"
  run validate-manifests
  [ "$status" -eq 0 ]
}

@test "validate-manifests allows --- inside a block scalar" {
  cat > "${TEST_RUN_BASE}/work/manifests/docs.yaml" << 'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: docs
data:
  readme.md: |
    Title
    ---
    Body
YAML
  run validate-manifests
  [ "$status" -eq 0 ]
}

@test "validate-manifests checks a run-platform's child sets for shape within the tree" {
  export ENVIRONMENT_TYPE="meta-env"
  write_manifest "${TEST_RUN_BASE}/work/manifests/run-platform-own/own-thing.yaml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/manifests/run-env-a/child.yml" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"manifests/run-env-a/child.yml"* ]]
}

# validate-manifests reads the complete tree and nothing else
#
# split-manifests copies every file out of work/manifests into the dir of the
# step that applies it. Those dirs hold nothing the tree does not, so the tree
# is validated once and the copies are never read here, on any kind of deploy.

write_set_manifest() {
  local dir="$1"
  local name="$2"
  mkdir -p "${dir}"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "${name}" > "${dir}/${name}.yaml"
}

@test "validate-manifests validates a run-platform's own and child sets as part of the tree" {
  export ENVIRONMENT_TYPE="meta-env"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-platform-own" own-thing
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-env-a" child-a
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-env-b" child-b
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-f ${TEST_RUN_BASE}/work/manifests/run-platform-own/own-thing.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  grep -q -- "-f ${TEST_RUN_BASE}/work/manifests/run-env-a/child-a.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
  grep -q -- "-f ${TEST_RUN_BASE}/work/manifests/run-env-b/child-b.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests validates nested files within a child set" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-env-a/nested/deeper" buried
  run validate-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-f ${TEST_RUN_BASE}/work/manifests/run-env-a/nested/deeper/buried.yaml" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "validate-manifests does not read the split dirs on a run-platform deploy" {
  export ENVIRONMENT_TYPE="meta-env"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a" child-a
  write_set_manifest "${TEST_RUN_BASE}/work/stages/deploy" staged
  run validate-manifests
  [ "$status" -eq 0 ]
  run grep -E "work/(self|seed|stages)/" "${TEST_RUN_BASE}/work/k-commands.log"
  [ "$status" -eq 1 ]
}

@test "validate-manifests does not read the split dirs on an environment deploy" {
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  write_set_manifest "${TEST_RUN_BASE}/work/seed/run-env-a" child-a
  write_set_manifest "${TEST_RUN_BASE}/work/stages/deploy" staged
  run validate-manifests
  [ "$status" -eq 0 ]
  run grep -E "work/(self|seed|stages)/" "${TEST_RUN_BASE}/work/k-commands.log"
  [ "$status" -eq 1 ]
}

@test "validate-manifests fails with an empty tree even when a split dir holds manifests" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/self" own-thing
  write_set_manifest "${TEST_RUN_BASE}/work/stages/deploy" staged
  run validate-manifests
  [ "$status" -eq 43 ]
  [[ "$output" == *"No manifest files"* ]]
}

@test "validate-manifests keeps audit files from different child sets apart" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/manifests" same-name
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-platform-own" same-name
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-env-a" same-name
  run validate-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/audit/validation/manifests_same-name.txt" ]
  [ -f "${TEST_RUN_BASE}/work/audit/validation/manifests_run-platform-own_same-name.txt" ]
  [ -f "${TEST_RUN_BASE}/work/audit/validation/manifests_run-env-a_same-name.txt" ]
}

@test "validate-manifests names the child set when one of its manifests fails" {
  export ENVIRONMENT_TYPE="meta-env"
  write_set_manifest "${TEST_RUN_BASE}/work/manifests/run-env-a" child-a
  install_mock_k_failing_dry_run

  run validate-manifests
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifests/run-env-a/child-a.yaml"* ]]
}

# apply-manifests tests
#
# It applies the deploy stage, which split-manifests fills from the complete
# tree, and never the tree itself: on a run-platform that would apply its own
# set and its seeded children too.

stage_fixture_manifests() {
  mkdir -p "${TEST_RUN_BASE}/work/stages/deploy"
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/stages/deploy/"
}

@test "apply-manifests calls k apply" {
  stage_fixture_manifests
  run apply-manifests
  [ "$status" -eq 0 ]
  grep -q "apply --server-side --field-manager=kaptain/env/test-env -R -f" "${TEST_RUN_BASE}/work/k-commands.log"
}

@test "apply-manifests applies the deploy stage, not the complete tree" {
  stage_fixture_manifests
  cp "${TEST_RUN_BASE}/manifests/"* "${TEST_RUN_BASE}/work/manifests/"
  run apply-manifests
  [ "$status" -eq 0 ]
  grep -q -- "-R -f ${TEST_RUN_BASE}/work/stages/deploy/" "${TEST_RUN_BASE}/work/k-commands.log"
  run grep -- "-f ${TEST_RUN_BASE}/work/manifests" "${TEST_RUN_BASE}/work/k-commands.log"
  [ "$status" -eq 1 ]
}

@test "apply-manifests creates audit log" {
  stage_fixture_manifests
  run apply-manifests
  [ "$status" -eq 0 ]
  [ -f "${TEST_RUN_BASE}/work/audit/apply.log" ]
}

@test "apply-manifests notifies on success" {
  stage_fixture_manifests
  run apply-manifests
  [ "$status" -eq 0 ]
  [[ "$output" =~ Main\ deploy\ performed\ in\ [0-9]+\ seconds?\. ]]
}

@test "apply-manifests records when the main deploy began" {
  stage_fixture_manifests
  install_mock_clock
  clock_reads 1234
  run apply-manifests
  [ "$status" -eq 0 ]
  [ "$(<"${TEST_RUN_BASE}/work/main-deploy-began")" = "1234" ]
  [[ "$output" == *"Main deploy performed in 0 seconds."* ]]
}

@test "apply-manifests reports failure" {
  stage_fixture_manifests
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
