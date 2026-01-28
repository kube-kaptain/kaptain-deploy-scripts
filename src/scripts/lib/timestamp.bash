#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Human-readable timestamp formatting.
# Sources: do not execute directly.

# Format current time as human-readable: "14:32:12, 25th Jan 2026 UTC"
human_timestamp() {
  local day
  day=$(date -u '+%-d')

  local suffix
  if [[ ${day} -ge 11 && ${day} -le 13 ]]; then
    suffix="th"
  else
    case $((day % 10)) in
      1) suffix="st" ;;
      2) suffix="nd" ;;
      3) suffix="rd" ;;
      *) suffix="th" ;;
    esac
  fi

  echo "$(date -u '+%H:%M:%S'), ${day}${suffix} $(date -u '+%b %Y %Z')"
}
