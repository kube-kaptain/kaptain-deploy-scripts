#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Tests for notify-once: a message is sent unless it is the same as the last
# one for its purpose, in which case a dot is printed in its place and the
# count of them is sent ahead of the next different message.

load test_helper

setup() {
  setup_test_dirs
  install_mock_notify
  install_mock_clock
  clock_reads 1000
  SENT="${TEST_RUN_BASE}/work/notifications.log"
  STATE="${TEST_RUN_BASE}/work/notify-once"
}

teardown() {
  teardown_test_dirs
}

checksum_of() {
  local checksum
  checksum=$(printf '%s' "$1" | sha256sum)
  printf '%s' "${checksum%% *}"
}

# Sending

@test "notify-once sends the first message for a purpose" {
  run notify-once deploy-check "Waiting for api"
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Waiting for api" ]
  [ "$(<"${SENT}")" = "INFO: Waiting for api" ]
}

@test "notify-once does not send the same message again, and prints a dot with no newline in its place" {
  notify-once deploy-check "Waiting for api"
  run notify-once deploy-check "Waiting for api"
  [ "$status" -eq 0 ]
  [ "$output" = "." ]
  [ "$(wc -l < "${SENT}")" -eq 1 ]
}

@test "notify-once prints a row of dots for as long as the message repeats" {
  run bash -c 'for round in 1 2 3 4 5; do notify-once deploy-check "Waiting for api"; done'
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Waiting for api
...." ]
  [ "$(wc -l < "${SENT}")" -eq 1 ]
}

@test "notify-once ends the dots and sends the count ahead of the next different message" {
  run bash -c '
    for round in 1 2 3 4; do notify-once deploy-check "Waiting for api"; done
    notify-once deploy-check "api is ready"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Waiting for api
...
INFO: Prior message repeated 3 times over 0s
INFO: api is ready" ]
  [ "$(<"${SENT}")" = "INFO: Waiting for api
INFO: Prior message repeated 3 times over 0s
INFO: api is ready" ]
}

@test "notify-once sends no count for a prior message that was never held back" {
  notify-once deploy-check "Waiting for api"
  run notify-once deploy-check "api is ready"
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: api is ready" ]
  run grep -F "Prior message" "${SENT}"
  [ "$status" -eq 1 ]
}

@test "notify-once counts the seconds from when the prior message was first sent to when the next one arrives" {
  clock_reads 1000
  notify-once deploy-check "Waiting for api"
  clock_reads 1010
  notify-once deploy-check "Waiting for api"
  clock_reads 1020
  notify-once deploy-check "Waiting for api"
  clock_reads 1050
  run notify-once deploy-check "api is ready"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO: Prior message repeated 2 times over 50s"* ]]
}

@test "notify-once says time, not times, for a message held back once" {
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for api"
  clock_reads 1007
  run notify-once deploy-check "api is ready"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO: Prior message repeated 1 time over 7s"* ]]
}

@test "notify-once sends a message again when it comes back after a different one" {
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for db"
  run notify-once deploy-check "Waiting for api"
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Waiting for api" ]
  [ "$(wc -l < "${SENT}")" -eq 3 ]
}

@test "notify-once counts only what was held back since the message came back" {
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for db"
  clock_reads 2000
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for api"
  clock_reads 2030
  run notify-once deploy-check "api is ready"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO: Prior message repeated 1 time over 30s"* ]]
}

@test "notify-once treats messages that differ by anything at all as different" {
  notify-once deploy-check "Waiting for api: 1 of 3 ready"
  run notify-once deploy-check "Waiting for api: 2 of 3 ready"
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Waiting for api: 2 of 3 ready" ]
}

@test "notify-once holds back a message of several lines like any other" {
  local message="Waiting for:
  - api
  - db"
  notify-once deploy-check "${message}"
  run notify-once deploy-check "${message}"
  [ "$status" -eq 0 ]
  [ "$output" = "." ]
}

# Purposes

@test "notify-once keeps each purpose apart: the same message is sent once for each" {
  notify-once prerequisite-jobs "Waiting"
  run notify-once deploy-check "Waiting"
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Waiting" ]
}

@test "notify-once counts for one purpose are not ended by a message for another" {
  notify-once prerequisite-jobs "Waiting"
  notify-once prerequisite-jobs "Waiting"
  run notify-once deploy-check "Something else"
  [ "$status" -eq 0 ]
  [ "$output" = "INFO: Something else" ]
  clock_reads 1004
  run notify-once prerequisite-jobs "Done"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO: Prior message repeated 1 time over 4s"* ]]
}

# What is left behind

@test "notify-once keeps the message last sent, when, and how many times it was held back" {
  local checksum
  checksum=$(checksum_of "Waiting for api")
  clock_reads 1000
  notify-once deploy-check "Waiting for api"
  [ "$(<"${STATE}/deploy-check/last")" = "${checksum}|1000|1000|0" ]
  clock_reads 1010
  notify-once deploy-check "Waiting for api"
  clock_reads 1025
  notify-once deploy-check "Waiting for api"
  [ "$(<"${STATE}/deploy-check/last")" = "${checksum}|1000|1025|2" ]
}

@test "notify-once keeps the text of every distinct message" {
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "Waiting for api"
  notify-once deploy-check "api is ready"
  [ "$(<"${STATE}/deploy-check/messages/$(checksum_of "Waiting for api")")" = "Waiting for api" ]
  [ "$(<"${STATE}/deploy-check/messages/$(checksum_of "api is ready")")" = "api is ready" ]
  [ "$(find "${STATE}/deploy-check/messages" -type f | wc -l)" -eq 2 ]
}

@test "notify-once adds a line to the history for each message that has been succeeded" {
  clock_reads 1000
  notify-once deploy-check "Waiting for api"
  clock_reads 1010
  notify-once deploy-check "Waiting for api"
  [ ! -e "${STATE}/deploy-check/history" ]
  clock_reads 1040
  notify-once deploy-check "Waiting for db"
  clock_reads 1045
  notify-once deploy-check "All ready"
  [ "$(<"${STATE}/deploy-check/history")" = "1000|1040|1|$(checksum_of "Waiting for api")
1040|1045|0|$(checksum_of "Waiting for db")" ]
}

# Being called wrongly

@test "notify-once fails without a purpose and a message" {
  run notify-once
  [ "$status" -eq 42 ]
  run notify-once deploy-check
  [ "$status" -eq 42 ]
  run notify-once deploy-check ""
  [ "$status" -eq 42 ]
  run notify-once deploy-check "one" "two"
  [ "$status" -eq 42 ]
  [ ! -e "${SENT}" ]
  [ ! -e "${STATE}" ]
}

@test "notify-once refuses a purpose that is not a plain dir name" {
  for purpose in "../escape" "Deploy-Check" "deploy check" "deploy/check" "-deploy" "deploy-"; do
    run notify-once "${purpose}" "Waiting"
    [ "$status" -eq 42 ]
    [[ "$output" == *"the purpose names a dir"* ]]
  done
  [ ! -e "${SENT}" ]
  [ ! -e "${STATE}" ]
}
