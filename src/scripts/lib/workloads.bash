#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Shared by record-baseline, which writes down the restart count of every pod
# of a declared workload before the deploy, and monitor-environment, which
# holds each pod to that count after it. They have to find the same workloads
# and the same pods, so what decides both is here and nowhere else.

# Every pod template in a document: each map whose spec holds a containers
# list. That is a Pod itself, a Deployment's template, a CronJob's job template
# and the same in any custom kind. A CRD's schema describing such a thing has a
# map there, not a list, and is not matched.
# shellcheck disable=SC2016,SC2034 # A yq expression, not shell; used by sourcing scripts
POD_TEMPLATES='[.. | select(tag == "!!map") | select(.spec | tag == "!!map") | select(.spec.containers | tag == "!!seq")]'

# Applied to a pod: lets through only one whose restart count can still rise.
# Not one being deleted, and not one that has finished (Succeeded, Failed).
# shellcheck disable=SC2016,SC2034 # A yq expression, not shell; used by sourcing scripts
LIVE_PODS_ONLY='select(.metadata.deletionTimestamp == null) | select(.status.phase == "Pending" or .status.phase == "Running" or .status.phase == "Unknown")'

# Applied to a pod: its restarts, summed over its containers and init
# containers. Zero for a pod with no container statuses yet.
# shellcheck disable=SC2016,SC2034 # A yq expression, not shell; used by sourcing scripts
POD_RESTARTS='([.status.initContainerStatuses[].restartCount, .status.containerStatuses[].restartCount] | .[] as $count ireduce (0; . + $count))'
