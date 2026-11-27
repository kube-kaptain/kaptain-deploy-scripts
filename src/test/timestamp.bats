#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for lib/timestamp.bash: saying roughly how long ago something was.

load test_helper

setup() {
  source "${SCRIPTS_DIR}/lib/timestamp.bash"
}

@test "roughly_ago counts in seconds under a minute" {
  [ "$(roughly_ago 0)" = "~0 seconds ago" ]
  [ "$(roughly_ago 1)" = "~1 second ago" ]
  [ "$(roughly_ago 42)" = "~42 seconds ago" ]
  [ "$(roughly_ago 59)" = "~59 seconds ago" ]
}

@test "roughly_ago counts in whole minutes under an hour, rounded down" {
  [ "$(roughly_ago 60)" = "~1 minute ago" ]
  [ "$(roughly_ago 119)" = "~1 minute ago" ]
  [ "$(roughly_ago 890)" = "~14 minutes ago" ]
  [ "$(roughly_ago 3599)" = "~59 minutes ago" ]
}

@test "roughly_ago counts in whole hours under a day, rounded down" {
  [ "$(roughly_ago 3600)" = "~1 hour ago" ]
  [ "$(roughly_ago 14340)" = "~3 hours ago" ]
  [ "$(roughly_ago 86399)" = "~23 hours ago" ]
}

@test "roughly_ago counts in whole days from there on, rounded down" {
  [ "$(roughly_ago 86400)" = "~1 day ago" ]
  [ "$(roughly_ago 190800)" = "~2 days ago" ]
  [ "$(roughly_ago 8640000)" = "~100 days ago" ]
}
