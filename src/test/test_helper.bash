#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Common test helper for BATS tests.

SCRIPTS_DIR="/run/bin"
FIXTURES_DIR="/run/fixtures"

setup_test_dirs() {
  # Create base directories for RUN_BASE_PATH structure
  TEST_RUN_BASE=$(mktemp -d)
  TEST_MOUNT_BASE=$(mktemp -d)
  TEST_MOCK_BIN=$(mktemp -d)

  # Export paths that scripts use
  export RUN_BASE_PATH="${TEST_RUN_BASE}"
  export MOUNT_BASE_PATH="${TEST_MOUNT_BASE}"

  # Create required directory structure under RUN_BASE_PATH
  # Note: work subdirs (decrypted, manifests, audit, oci-images) are created by scripts
  mkdir -p "${TEST_RUN_BASE}/secrets"
  mkdir -p "${TEST_RUN_BASE}/manifests"
  mkdir -p "${TEST_RUN_BASE}/work"

  # Create required directory structure under MOUNT_BASE_PATH
  mkdir -p "${TEST_MOUNT_BASE}/secret"
  mkdir -p "${TEST_MOUNT_BASE}/configmap"

  # Put mock bin first on PATH so mocks take priority
  export PATH="${TEST_MOCK_BIN}:${SCRIPTS_DIR}:${PATH}"
}

teardown_test_dirs() {
  rm -rf "${TEST_RUN_BASE}" "${TEST_MOUNT_BASE}" "${TEST_MOCK_BIN}"
}

install_mock_k() {
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
# Return empty for jsonpath queries (oci-images)
if [[ "$*" == *"-o jsonpath"* ]] || [[ "$*" == *"-o go-template"* ]]; then
  exit 0
fi
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"
}

install_mock_kubectl() {
  cat > "${TEST_MOCK_BIN}/kubectl" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/kubectl-commands.log"
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/kubectl"
}

install_mock_notify() {
  # Mock notify-info
  cat > "${TEST_MOCK_BIN}/notify-info" << 'MOCK'
#!/usr/bin/env bash
echo "INFO: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "INFO: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-info"

  # Mock notify-error
  cat > "${TEST_MOCK_BIN}/notify-error" << 'MOCK'
#!/usr/bin/env bash
echo "ERROR: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "ERROR: $*" >&2
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-error"

  # Mock notify-warning
  cat > "${TEST_MOCK_BIN}/notify-warning" << 'MOCK'
#!/usr/bin/env bash
echo "WARNING: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "WARNING: $*" >&2
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-warning"

  # Mock log
  cat > "${TEST_MOCK_BIN}/log" << 'MOCK'
#!/usr/bin/env bash
echo "LOG: $*" >> "${RUN_BASE_PATH}/work/container.log"
MOCK
  chmod +x "${TEST_MOCK_BIN}/log"
}

install_mock_sleep() {
  local real_sleep
  real_sleep="$(which sleep)"
  cat > "${TEST_MOCK_BIN}/sleep" << MOCK
#!/usr/bin/env bash
# For large values (deploy's while-true loop), kill parent to break out.
# For small values (test timing), use real sleep.
arg="\${1:-0}"
int="\${arg%%.*}"
if [[ "\${int}" -ge 60 ]] 2>/dev/null; then
  kill -TERM "\$PPID" 2>/dev/null
  exit 0
fi
exec "${real_sleep}" "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/sleep"
}

install_mock_validate_container() {
  cat > "${TEST_MOCK_BIN}/validate-container" << 'MOCK'
#!/usr/bin/env bash
# Mock validation - always passes
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/validate-container"
}

install_mock_validate_token_styles() {
  cat > "${TEST_MOCK_BIN}/validate_token_styles" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/validate_token_styles"
}

install_mock_oci_images() {
  cat > "${TEST_MOCK_BIN}/oci-images" << 'MOCK'
#!/usr/bin/env bash
label="$1"
output_dir="${RUN_BASE_PATH}/work/oci-images"
mkdir -p "${output_dir}"
touch "${output_dir}/oci-images-${label}-unsorted"
touch "${output_dir}/oci-images-${label}-sorted"
MOCK
  chmod +x "${TEST_MOCK_BIN}/oci-images"
}

install_mock_notify_oci_images_changed() {
  cat > "${TEST_MOCK_BIN}/notify-oci-images-changed" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-oci-images-changed"
}

copy_fixture_manifests() {
  cp "${FIXTURES_DIR}/manifests/"* "${TEST_RUN_BASE}/manifests/"
}

copy_fixture_templates() {
  cp "${FIXTURES_DIR}/templates/"* "${TEST_RUN_BASE}/manifests/"
}

copy_fixture_secrets() {
  # Copy secrets to the secrets dir (excluding passphrase)
  for f in "${FIXTURES_DIR}/secrets/"*; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    if [[ "${fname}" != "environmentPassphrase" ]]; then
      cp "$f" "${TEST_RUN_BASE}/secrets/"
    fi
  done
  # Copy passphrase to the mount secret dir
  cp "${FIXTURES_DIR}/secrets/environmentPassphrase" "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
}
