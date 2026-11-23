#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Shared by the scripts that wait by asking the cluster in rounds.

# How long to pause before the next round of asking, in seconds.
#
# Fast at first, so that what comes up quickly is seen quickly, then slower the
# longer the wait has gone on, to take the load off the API server. It is the
# fastest period, doubled once for each doubling period that has passed since
# the wait began, up to a number of doublings and no further.
#
#   poll_period <seconds waited so far> <fastest period> <doubling period> <doublings>
#
# With 5, 60 and 3: 5s for the first minute, 10s for the second, 20s for the
# third and 40s from there on. A doubling period of 0 never doubles.
poll_period() {
  local waited="$1"
  local fastest="$2"
  local double_after="$3"
  local doubles="$4"

  local doublings=0
  if [[ "${double_after}" -gt 0 ]]; then
    doublings=$(( waited / double_after ))
    if [[ "${doublings}" -gt "${doubles}" ]]; then
      doublings="${doubles}"
    fi
  fi

  printf '%s' "$(( fastest << doublings ))"
}
