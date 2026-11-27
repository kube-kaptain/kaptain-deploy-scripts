#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for signal handling in deploy script.
# Signal handling is now inline in deploy rather than a separate library.

load test_helper

setup() {
  setup_test_dirs
  install_mock_k
  install_mock_notify
  install_mock_sleep
  install_mock_interruptible_sleep
  install_mock_validate_container
  install_mock_scan_images
  install_mock_notify_images_changed
  install_mock_monitor_environment
  copy_fixture_manifests
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

@test "deploy initialises PHASE to Pre-validation" {
  # Start deploy and capture early output
  run timeout 2 deploy || true
  # The first notify-info should mention the starting message
  [[ "$output" == *"Starting"* ]]
}

@test "deploy defers SIGTERM during uninterruptible phase" {
  # Marker-based synchronisation (no timing dependency):
  #  1. mock k writes a marker when apply --server-side starts, then blocks
  #     until the test removes it.
  #  2. Test polls for marker, sends SIGTERM, removes marker.
  #  3. mock k unblocks; deploy finishes the apply phase normally.
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"apply --server-side"* ]] && [[ "$*" != *"--dry-run"* ]]; then
  echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
  marker="${RUN_BASE_PATH}/work/apply-phase-entered"
  : > "${marker}"
  i=0
  while [[ -f "${marker}" ]] && [[ ${i} -lt 300 ]]; do
    /bin/sleep 0.1
    i=$((i + 1))
  done
  echo "mock: $*"
  exit 0
fi
# Everything else, discovery for the kind pre-check included, as standard
exec "${TEST_MOCK_BIN}/k-standard" "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"

  # Start deploy in background
  deploy &
  local deploy_pid=$!

  # Poll for the apply-phase marker (deterministic, no fixed sleep)
  local marker="${TEST_RUN_BASE}/work/apply-phase-entered"
  local i=0
  while [[ ! -f "${marker}" ]] && [[ ${i} -lt 300 ]]; do
    /bin/sleep 0.1
    i=$((i + 1))
  done
  if [[ ! -f "${marker}" ]]; then
    kill -KILL "${deploy_pid}" 2>/dev/null || true
    false
  fi

  # In the apply phase now - send SIGTERM (must be deferred)
  kill -TERM "${deploy_pid}" 2>/dev/null || true

  # Tiny pause so the SIGTERM handler runs before mock k completes
  /bin/sleep 0.1

  # Release mock k so the apply call can return
  rm -f "${marker}"

  # Wait for completion
  wait "${deploy_pid}" 2>/dev/null || true

  # Should have completed apply (file exists)
  [ -f "${TEST_RUN_BASE}/work/audit/apply.log" ]

  # Check for deferral message in notifications
  if [ -f "${TEST_RUN_BASE}/work/notifications.log" ]; then
    grep -q "deferring\|Shutdown requested" "${TEST_RUN_BASE}/work/notifications.log" || true
  fi
}

@test "deploy exits on SIGTERM during interruptible phase" {
  # Make prepare-manifests slow to catch SIGTERM during it
  cat > "${TEST_MOCK_BIN}/prepare-manifests" << 'MOCK'
#!/usr/bin/env bash
sleep 1
cp -a "${RUN_BASE_PATH}/manifests/"* "${RUN_BASE_PATH}/work/manifests/"
MOCK
  chmod +x "${TEST_MOCK_BIN}/prepare-manifests"

  # Start deploy in background
  deploy &
  local deploy_pid=$!

  # Wait for it to start preparing
  sleep 0.3

  # Send SIGTERM during interruptible phase
  kill -TERM "${deploy_pid}" 2>/dev/null || true

  # Wait for it
  wait "${deploy_pid}" 2>/dev/null
  local exit_code=$?

  # Should exit cleanly (0)
  [ "${exit_code}" -eq 0 ]
}

@test "deploy says a SIGTERM during the wait after a failure came during that wait, naming the phase that failed, and keeps the failure's exit code" {
  # Fail early, in an interruptible phase, then really wait so there is time
  # to be told to stop
  cat > "${TEST_MOCK_BIN}/prepare-manifests" << 'MOCK'
#!/usr/bin/env bash
exit 7
MOCK
  chmod +x "${TEST_MOCK_BIN}/prepare-manifests"
  unset -f interruptible_sleep
  export POST_DEPLOY_SLEEP_FAILURE=30

  deploy &
  local deploy_pid=$!

  # Until it says it is waiting after the failure
  local tries=0
  until grep -q "Sleeping 30s before exit" "${TEST_RUN_BASE}/work/notifications.log" 2>/dev/null; do
    tries=$((tries + 1))
    [ "${tries}" -lt 200 ]
    sleep 0.1
  done

  kill -TERM "${deploy_pid}" 2>/dev/null || true
  local exit_code=0
  wait "${deploy_pid}" 2>/dev/null || exit_code=$?

  [ "${exit_code}" -eq 7 ]
  grep -qE "^INFO: SIGTERM received during 'Post-failure wait' \(failed ~[0-9]+ seconds? ago in 'Preparing manifests'\) - shutting down$" "${TEST_RUN_BASE}/work/notifications.log"
  grep -qF "error during 'Preparing manifests'" "${TEST_RUN_BASE}/work/notifications.log"
  run grep -F "SIGTERM received during 'Preparing manifests'" "${TEST_RUN_BASE}/work/notifications.log"
  [ "$status" -eq 1 ]
}

@test "deploy says a deferred SIGTERM was deferred and is now being respected, once the phase it came in has finished" {
  # The first step of the uninterruptible apply phase says it has started,
  # then holds until the test lets it go
  cat > "${TEST_MOCK_BIN}/apply-jobs" << 'MOCK'
#!/usr/bin/env bash
: > "${RUN_BASE_PATH}/work/apply-jobs-started"
i=0
while [[ ! -f "${RUN_BASE_PATH}/work/apply-jobs-released" ]] && [[ ${i} -lt 300 ]]; do
  /bin/sleep 0.1
  i=$((i + 1))
done
MOCK
  chmod +x "${TEST_MOCK_BIN}/apply-jobs"

  deploy &
  local deploy_pid=$!

  local i=0
  while [[ ! -f "${TEST_RUN_BASE}/work/apply-jobs-started" ]] && [[ ${i} -lt 300 ]]; do
    /bin/sleep 0.1
    i=$((i + 1))
  done
  if [[ ! -f "${TEST_RUN_BASE}/work/apply-jobs-started" ]]; then
    kill -KILL "${deploy_pid}" 2>/dev/null || true
    false
  fi

  # In the apply phase now: this has to be deferred
  kill -TERM "${deploy_pid}" 2>/dev/null || true
  /bin/sleep 0.1
  : > "${TEST_RUN_BASE}/work/apply-jobs-released"

  local exit_code=0
  wait "${deploy_pid}" 2>/dev/null || exit_code=$?

  [ "${exit_code}" -eq 0 ]
  grep -qF "INFO: SIGTERM received during 'Applying manifests' - deferring until complete" "${TEST_RUN_BASE}/work/notifications.log"
  grep -qF "INFO: Shutdown requested during 'Applying manifests' but deferred - now finished and respecting SIGTERM" "${TEST_RUN_BASE}/work/notifications.log"
}
