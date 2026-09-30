#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for echo-only mode.
#
# The environment build runs validate-environment against the freshly built
# image, in a build job with no credentials mounted for any chat provider.
# Those providers must not run there at all, or every build gets a log full of
# their complaints. In the cluster they must run as normal.

load test_helper

# Fake providers are installed as siblings of the dispatchers, which is how the
# real ones are found. Named so nothing could mistake them for a real provider.
PROVIDER_SUFFIX="bats-test-suite"

setup() {
  setup_test_dirs

  # Everything validate-environment needs to pass on its own merits
  export DEPLOY_MODE="job"
  export ENVIRONMENT="run-test-env"
  export ENVIRONMENT_TYPE="env"
  export VERSION="v1.0.0"
  export TOKEN_DELIMITER_STYLE="shell"
  export TOKEN_NAME_STYLE="PascalCase"
  write_cleanup_policy_configmap

  # Deliberately no install_mock_notify here: these tests need the real
  # dispatchers, since the fan-out is what is being tested.
  export PROVIDER_LOG="${TEST_RUN_BASE}/work/provider-calls.log"
  install_fake_providers
}

teardown() {
  rm -f "${SCRIPTS_DIR}"/*"-${PROVIDER_SUFFIX}"
  teardown_test_dirs
}

# A stand-in for a chat provider, one per dispatcher. Records that it ran and
# complains on stderr the way a real one would with no credentials present.
install_fake_providers() {
  local dispatcher
  for dispatcher in notify-info notify-warning notify-error alert; do
    cat > "${SCRIPTS_DIR}/${dispatcher}-${PROVIDER_SUFFIX}" << MOCK
#!/usr/bin/env bash
echo "${dispatcher}-${PROVIDER_SUFFIX}: \$*" >> "\${PROVIDER_LOG}"
echo "${dispatcher}-${PROVIDER_SUFFIX}: no credentials configured" >&2
MOCK
    chmod +x "${SCRIPTS_DIR}/${dispatcher}-${PROVIDER_SUFFIX}"
  done
}

provider_ran() {
  [[ -f "${PROVIDER_LOG}" ]] && grep -q "${1}-${PROVIDER_SUFFIX}" "${PROVIDER_LOG}"
}

# --- Dispatchers fan out normally when echo-only is not set ---

@test "notify-info runs installed providers by default" {
  run notify-info "info message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"info message"* ]]
  provider_ran notify-info
}

@test "notify-warning runs installed providers by default" {
  run notify-warning "warning message"
  [ "$status" -eq 0 ]
  provider_ran notify-warning
}

@test "notify-error runs installed providers by default" {
  run notify-error "error message"
  [ "$status" -eq 0 ]
  provider_ran notify-error
}

@test "alert runs installed providers by default" {
  run alert "alert message"
  [ "$status" -eq 0 ]
  provider_ran alert
}

# --- Echo-only mode runs the built-in and nothing else ---

@test "notify-info runs only the built-in echo provider in echo-only mode" {
  export NOTIFY_ECHO_ONLY=true
  run notify-info "info message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"info message"* ]]
  ! provider_ran notify-info
}

@test "notify-warning runs only the built-in echo provider in echo-only mode" {
  export NOTIFY_ECHO_ONLY=true
  run notify-warning "warning message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  ! provider_ran notify-warning
}

@test "notify-error runs only the built-in echo provider in echo-only mode" {
  export NOTIFY_ECHO_ONLY=true
  run notify-error "error message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR"* ]]
  ! provider_ran notify-error
}

@test "alert runs only the built-in echo provider in echo-only mode" {
  export NOTIFY_ECHO_ONLY=true
  run alert "alert message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALERT"* ]]
  ! provider_ran alert
}

@test "echo-only mode attributes output to the same caller as normal mode" {
  # The exec must happen after NOTIFY_CALLER is worked out, or build output
  # would be attributed differently to everything else. Comparing the two modes
  # rather than asserting a name keeps this independent of whether ps can see
  # the caller on a given base image.
  cat > "${TEST_MOCK_BIN}/notify-caller-probe" << 'MOCK'
#!/usr/bin/env bash
notify-info "probe message"
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-caller-probe"

  normal="$(notify-caller-probe)"
  export NOTIFY_ECHO_ONLY=true
  echo_only="$(notify-caller-probe)"

  # Drop the leading timestamp, which differs between the two runs
  [[ "${normal#* }" == "${echo_only#* }" ]]
}

# --- The flag that turns it on ---

@test "validate-environment --notify-echo-only passes and runs no providers" {
  run validate-environment --notify-echo-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"validation passed"* ]]
  ! provider_ran notify-info
}

@test "validate-environment without the flag runs providers as normal" {
  run validate-environment
  [ "$status" -eq 0 ]
  provider_ran notify-info
}

@test "validate-environment --notify-echo-only runs no providers when it fails" {
  unset VERSION
  run validate-environment --notify-echo-only
  [ "$status" -eq 44 ]
  [[ "$output" == *"VERSION must be set"* ]]
  ! provider_ran notify-error
}

@test "validate-environment rejects an unknown argument" {
  run validate-environment --notify-echo-onlyy
  [ "$status" -eq 42 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "validate-environment rejects more than one argument" {
  run validate-environment --notify-echo-only extra
  [ "$status" -eq 42 ]
  [[ "$output" == *"At most one argument"* ]]
}

@test "validate-environment does not pass the flag to plugin validators" {
  cat > "${SCRIPTS_DIR}/validate-environment-${PROVIDER_SUFFIX}" << MOCK
#!/usr/bin/env bash
echo "validate-environment-${PROVIDER_SUFFIX}: [\$*]" >> "\${PROVIDER_LOG}"
MOCK
  chmod +x "${SCRIPTS_DIR}/validate-environment-${PROVIDER_SUFFIX}"

  run validate-environment --notify-echo-only
  [ "$status" -eq 0 ]
  grep -q "validate-environment-${PROVIDER_SUFFIX}: \[\]" "${PROVIDER_LOG}"
}
