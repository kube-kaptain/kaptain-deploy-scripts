#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for notification formatting - caller width constant.

load test_helper

setup() {
  setup_test_dirs
}

teardown() {
  teardown_test_dirs
}

@test "NOTIFY_CALLER_WIDTH matches longest caller name plus colon" {
  NOTIFY_CALLER_WIDTH=$(cat "${SCRIPTS_DIR}/lib/notify-caller-width")

  # Find the longest name among scripts that call log/notify/alert
  local max_len=14  # UNKNOWN_CALLER
  for script in "${SCRIPTS_DIR}"/*; do
    [[ -f "$script" ]] || continue
    local name
    name=$(basename "$script")

    # Skip routers, echo providers, and non-caller scripts
    case "$name" in
      notify-info|notify-error|notify-warning|alert|log) continue ;;
      *-echo) continue ;;
      k) continue ;;
    esac

    # Check if this script calls any notification function
    if grep -qE '\b(notify-info|notify-error|notify-warning|alert|log)\b' "$script"; then
      local len=${#name}
      if [[ $len -gt $max_len ]]; then
        max_len=$len
      fi
    fi
  done

  local expected=$((max_len + 1))  # +1 for the colon
  echo "Longest caller: ${max_len} chars, expected width: ${expected}, actual: ${NOTIFY_CALLER_WIDTH}"
  [ "${NOTIFY_CALLER_WIDTH}" -eq "${expected}" ]
}
