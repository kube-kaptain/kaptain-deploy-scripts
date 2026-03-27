#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Logging bridge: shared-scripts log interface → deploy notify-echo providers.

# Duplicated in src/scripts/log - keep in sync
_log_notify_caller() {
  NOTIFY_CALLER=$(ps -o args= -p ${PPID} 2>/dev/null | \
    awk '{
           cmd = ($1 ~ /(bash|sh)$/) ? $2 : $1
           n = split(cmd, parts, "/")
           print parts[n]
         }') || true
  export NOTIFY_CALLER="${NOTIFY_CALLER:-UNKNOWN_CALLER}"
}

log() { command log "$@"; }
log_error() { _log_notify_caller; notify-error-echo "$@"; }
log_warning() { _log_notify_caller; notify-warning-echo "$@"; }
