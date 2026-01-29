#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for the validate-tooling script.
# This should be the first test run - validates the base image has required tools.

@test "validate-tooling passes on valid base image" {
  run validate-tooling
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 failed"* ]]
}
