#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Shared by the scripts that compare a set of manifests with the cluster and
# reapply it when it differs: a run-platform's own set and its seeded children.

# The image of every container and init container, wherever the pod spec sits
# (a Deployment's template, a CronJob's job template and so on). Matched by
# position in a containers list, so an "image" key anywhere else, a ConfigMap's
# data or an image volume say, is left alone.
# shellcheck disable=SC2016,SC2034 # A yq expression, not shell; used by sourcing scripts
CONTAINER_IMAGES='.. | select(tag == "!!map" and has("image")) | select(path | join("/") | test("/(containers|initContainers)/[0-9]+$")) | .image'

# What a compare ignores, stripped from both the live object and the object an
# apply would make before the two are compared:
#
#   - status and the server's own bookkeeping
#   - Kaptain's own labels and annotations, which change with every build:
#     every kaptain.org/ key, and app.kubernetes.io/version, which the
#     generators also stamp. On the object, its pod template and its job
#     template. Every other label and annotation counts, whoever put it there.
#   - the tag or digest of each container image. The repository still counts.
#     The image auto-updater owns the tag, so a newer one is not a difference.
# shellcheck disable=SC2016,SC2034 # A yq expression, not shell; used by sourcing scripts
COMPARE_STRIP='
  del(.status)
  | del(
      .metadata.managedFields,
      .metadata.resourceVersion,
      .metadata.generation,
      .metadata.uid,
      .metadata.creationTimestamp,
      .metadata.selfLink
    )
  | del(
      (.metadata, .spec.template.metadata, .spec.jobTemplate.metadata, .spec.jobTemplate.spec.template.metadata)
      | (.labels, .annotations)
      | .[]
      | select((key | test("^kaptain\.org/")) or key == "app.kubernetes.io/version")
    )
  | ('"${CONTAINER_IMAGES}"') |= (sub("@.*$"; "") | sub(":[^:/]*$"; ""))
'

# Whether a manifest file is the CronJob that runs an environment's deploys in
# job mode: named plainly for the environment, suspended, and carrying keelson
# annotations, since keelson is what mutates and triggers it. Any other CronJob
# in the same set is just one of that environment's ordinary resources.
# shellcheck disable=SC2016 # A yq expression, not shell
is_deployer_cronjob() {
  local file="$1"
  local deployer="$2"
  [[ "$(DEPLOYER="${deployer}" yq '.kind == "CronJob" and .metadata.name == strenv(DEPLOYER) and .spec.suspend == true and ((.metadata.annotations // {}) | keys | any_c(test("^keelson\.pro/")))' "${file}")" == "true" ]]
}

# Whether a manifest file is the Deployment that runs an environment's deploys
# in deployment mode: the one named plainly for the environment.
# shellcheck disable=SC2016 # A yq expression, not shell
is_deployer_deployment() {
  local file="$1"
  local deployer="$2"
  [[ "$(DEPLOYER="${deployer}" yq '.kind == "Deployment" and .metadata.name == strenv(DEPLOYER)' "${file}")" == "true" ]]
}

# The field manager every deploy of this environment applies under
field_manager() {
  printf 'kaptain/%s/%s' "${ENVIRONMENT_TYPE:-}" "${ENVIRONMENT:-}"
}

# The differences a compare found, on one line for a chat message:
# "deployment.yaml differs, configmap.yaml missing"
differences_summary() {
  local differences_file="$1"
  local summary=""
  local difference
  while IFS= read -r difference; do
    summary+="${summary:+, }${difference}"
  done < "${differences_file}"
  printf '%s' "${summary}"
}

# The live template of the workload a manifest file declares: a Deployment's pod
# template, a CronJob's job template. Empty when the workload is not in the
# cluster. Read before and after an apply, it says whether the apply changed
# what the workload runs.
live_workload_template() {
  local file="$1"
  local document
  local error_file
  error_file="$(mktemp)"

  if document=$(k get -f "${file}" -o yaml 2> "${error_file}"); then
    rm -f "${error_file}"
    yq '.spec.jobTemplate // .spec.template // ""' <<< "${document}"
  elif grep -q "(NotFound)" "${error_file}"; then
    rm -f "${error_file}"
  else
    cat "${error_file}" >&2
    rm -f "${error_file}"
    return 1
  fi
}
