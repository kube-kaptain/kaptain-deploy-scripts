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

@test "validate-manifests pre-checks held-back sets too" {
  export ENVIRONMENT_TYPE="meta-env"
  write_manifest "${TEST_RUN_BASE}/work/self/own-thing.yaml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/seed/run-env-a/widget.yaml" example.com/v1 Widget
  run validate-manifests
  [ "$status" -eq 50 ]
  [[ "$output" == *"seed/run-env-a/widget.yaml: example.com/v1 Widget"* ]]
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

@test "validate-manifests checks held-back sets for shape too" {
  export ENVIRONMENT_TYPE="meta-env"
  write_manifest "${TEST_RUN_BASE}/work/self/own-thing.yaml" v1 ConfigMap
  write_manifest "${TEST_RUN_BASE}/work/seed/run-env-a/child.yml" v1 ConfigMap
  run validate-manifests
  [ "$status" -eq 51 ]
  [[ "$output" == *"seed/run-env-a/child.yml"* ]]
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
  install_mock_k_failing_dry_run

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
