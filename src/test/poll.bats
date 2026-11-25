#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/poll.bash: how long to pause between rounds of asking the
# cluster, fast at first and slower the longer the wait has gone on.

load test_helper

setup() {
  source "${SCRIPTS_DIR}/lib/poll.bash"
}

@test "poll_period is the fastest period until the first doubling period has passed" {
  [ "$(poll_period 0 5 60 3)" = "5" ]
  [ "$(poll_period 59 5 60 3)" = "5" ]
}

@test "poll_period doubles once for each doubling period that has passed" {
  [ "$(poll_period 60 5 60 3)" = "10" ]
  [ "$(poll_period 119 5 60 3)" = "10" ]
  [ "$(poll_period 120 5 60 3)" = "20" ]
  [ "$(poll_period 180 5 60 3)" = "40" ]
}

@test "poll_period stops doubling after the number of doublings it was given" {
  [ "$(poll_period 240 5 60 3)" = "40" ]
  [ "$(poll_period 86400 5 60 3)" = "40" ]
  [ "$(poll_period 86400 5 60 1)" = "10" ]
}

@test "poll_period never doubles when given no doublings, or a doubling period of 0" {
  [ "$(poll_period 86400 5 60 0)" = "5" ]
  [ "$(poll_period 86400 5 0 3)" = "5" ]
}
