#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for validate-notify, which runs the notify plugins' own validators
# before the first message of a deploy. A plugin's validator decides for itself
# whether a problem blocks: non-zero blocks, zero carries on.

load test_helper

# Fake validators are installed as siblings, which is how the real ones are
# found. Named so nothing could mistake them for a real plugin.
VALIDATOR_PREFIX="validate-notify-bats-test-suite"

setup() {
  setup_test_dirs
  export VALIDATOR_LOG="${TEST_RUN_BASE}/work/validator-calls.log"
}

teardown() {
  rm -f "${SCRIPTS_DIR}/${VALIDATOR_PREFIX}"*
  teardown_test_dirs
}

# Usage: install_validator <name-suffix> <exit-code>
install_validator() {
  cat > "${SCRIPTS_DIR}/${VALIDATOR_PREFIX}-${1}" << MOCK
#!/usr/bin/env bash
echo "${1}" >> "\${VALIDATOR_LOG}"
exit ${2}
MOCK
  chmod +x "${SCRIPTS_DIR}/${VALIDATOR_PREFIX}-${1}"
}

@test "validate-notify passes with no plugins installed" {
  run validate-notify
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notify validation passed"* ]]
}

@test "validate-notify runs every plugin validator" {
  install_validator one 0
  install_validator two 0
  run validate-notify
  [ "$status" -eq 0 ]
  grep -q "^one$" "${VALIDATOR_LOG}"
  grep -q "^two$" "${VALIDATOR_LOG}"
}

@test "validate-notify fails with 44 when a plugin validator blocks, after running them all" {
  install_validator blocks 1
  install_validator zpasses 0
  run validate-notify
  [ "$status" -eq 44 ]
  [[ "$output" == *"Notify validation failed with 1 error"* ]]
  grep -q "^zpasses$" "${VALIDATOR_LOG}"
}

@test "validate-notify counts every blocking validator" {
  install_validator one 1
  install_validator two 1
  run validate-notify
  [ "$status" -eq 44 ]
  [[ "$output" == *"Notify validation failed with 2 errors"* ]]
}

@test "validate-notify fails a validator that is not executable" {
  install_validator noexec 0
  chmod -x "${SCRIPTS_DIR}/${VALIDATOR_PREFIX}-noexec"
  run validate-notify
  [ "$status" -eq 44 ]
  [[ "$output" == *"is not executable"* ]]
}

@test "validate-notify never sends a notify message" {
  install_mock_notify
  install_validator blocks 1
  run validate-notify
  [ ! -e "${RUN_BASE_PATH}/work/notifications.log" ]
}
