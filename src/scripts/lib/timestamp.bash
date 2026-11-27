#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Human-readable timestamp formatting.
# Sources: do not execute directly.

# How long ago something was, roughly, from the seconds since: the largest
# whole unit, rounded down. "~42 seconds ago", "~1 hour ago", "~3 days ago"
roughly_ago() {
  local seconds="$1"
  local count
  local unit

  if [[ ${seconds} -ge 86400 ]]; then
    count=$(( seconds / 86400 ))
    unit="day"
  elif [[ ${seconds} -ge 3600 ]]; then
    count=$(( seconds / 3600 ))
    unit="hour"
  elif [[ ${seconds} -ge 60 ]]; then
    count=$(( seconds / 60 ))
    unit="minute"
  else
    count="${seconds}"
    unit="second"
  fi

  if [[ ${count} -ne 1 ]]; then
    unit+="s"
  fi
  printf '~%s %s ago' "${count}" "${unit}"
}

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
