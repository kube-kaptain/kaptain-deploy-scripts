#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# Common test helper for BATS tests.

SCRIPTS_DIR="${SCRIPTS_DIR:-/kd/bin}"
FIXTURES_DIR="${FIXTURES_DIR:-/kd/fixtures}"

setup_test_dirs() {
  # Create base directories for RUN_BASE_PATH structure
  TEST_RUN_BASE=$(mktemp -d)
  TEST_MOUNT_BASE=$(mktemp -d)
  TEST_MOCK_BIN=$(mktemp -d)

  # Export paths that scripts use
  export RUN_BASE_PATH="${TEST_RUN_BASE}"
  export MOUNT_BASE_PATH="${TEST_MOUNT_BASE}"
  # Exported so a mock can delegate to another mock beside it
  export TEST_MOCK_BIN

  # Create required directory structure under RUN_BASE_PATH
  # Note: work subdirs (decrypted, manifests, audit, baseline) are created by scripts
  mkdir -p "${TEST_RUN_BASE}/secrets"
  mkdir -p "${TEST_RUN_BASE}/manifests"
  mkdir -p "${TEST_RUN_BASE}/work"

  # Create required directory structure under MOUNT_BASE_PATH
  mkdir -p "${TEST_MOUNT_BASE}/secret"
  mkdir -p "${TEST_MOUNT_BASE}/configmap"

  # Put mock bin first on PATH so mocks take priority
  export PATH="${TEST_MOCK_BIN}:${SCRIPTS_DIR}:${PATH}"
}

teardown_test_dirs() {
  rm -rf "${TEST_RUN_BASE}" "${TEST_MOUNT_BASE}" "${TEST_MOCK_BIN}"
}

install_mock_k() {
  # Discovery for validate-manifests' kind pre-check. Defaults cover what the
  # fixtures declare; a test wanting more calls serve_discovery itself.
  serve_discovery /api/v1 ConfigMap Secret Service ServiceAccount Namespace
  serve_discovery /apis/apps/v1 Deployment StatefulSet DaemonSet
  serve_discovery /apis/batch/v1 Job CronJob
  serve_discovery /apis/apiextensions.k8s.io/v1 CustomResourceDefinition

  cat > "${TEST_MOCK_BIN}/k-standard" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"

# Discovery: one file per served group/version, 404 for anything else
if [[ "$1" == "get" ]] && [[ "$2" == "--raw" ]]; then
  served_file="${RUN_BASE_PATH}/work/mock-k-discovery/${3//\//_}"
  if [[ ! -f "${served_file}" ]]; then
    echo "Error from server (NotFound): the server could not find the requested resource" >&2
    exit 1
  fi
  printf '{"kind":"APIResourceList","resources":['
  separator=""
  for served_kind in $(<"${served_file}"); do
    printf '%s{"name":"mocks","kind":"%s"}' "${separator}" "${served_kind}"
    separator=","
  done
  printf ']}\n'
  exit 0
fi

# get customresourcedefinition <name>: is it Established yet? Yes, unless a
# test said it takes some rounds of asking with crd_established_after
if [[ "$1" == "get" && "$2" == "customresourcedefinition" ]]; then
  rounds_file="${RUN_BASE_PATH}/work/mock-k-cluster/crd-rounds-$3"
  rounds_left=0
  if [[ -f "${rounds_file}" ]]; then
    rounds_left=$(<"${rounds_file}")
  fi
  if [[ "${rounds_left}" -gt 0 ]]; then
    echo "$((rounds_left - 1))" > "${rounds_file}"
    exit 0
  fi
  echo "True"
  exit 0
fi

# create: works unless a test said otherwise
if [[ "$1" == "create" && -f "${RUN_BASE_PATH}/work/mock-k-cluster/create-fails" ]]; then
  echo "Error from server (Forbidden): mocks is forbidden" >&2
  exit 1
fi

# get pods -o json: every pod a test has put in the namespace with live_pod,
# as the list kubectl answers with
if [[ "$*" == "get pods -o json" ]]; then
  if [[ -f "${RUN_BASE_PATH}/work/mock-k-cluster/pods-fails" ]]; then
    echo "Error from server (Forbidden): pods is forbidden" >&2
    exit 1
  fi
  printf '{"apiVersion":"v1","kind":"List","items":['
  separator=""
  for pod_file in "${RUN_BASE_PATH}/work/mock-k-cluster/pods"/*; do
    [[ -f "${pod_file}" ]] || continue
    printf '%s%s' "${separator}" "$(<"${pod_file}")"
    separator=","
  done
  printf ']}\n'
  exit 0
fi

# get deployments,statefulsets,daemonsets,jobs,pods -o json: what
# monitor-environment asks each round. A test describes the cluster as it is
# from some round on by putting one JSON object per file in a dir named for
# that round, mock-k-cluster/snapshot/<round>. Each ask gets the latest round
# described that is not after it. Nothing described is an empty namespace.
#
# get replicasets -o json: the ReplicaSet-* files of that same round, which it
# asks for only when a Deployment is part way through a rollout.
#
# A test makes the first sort of ask fail with a snapshot-fails file: every
# time if it is empty, or for as many asks as the number in it.
if [[ "$*" == "get replicasets -o json" ]]; then
  snapshots="${RUN_BASE_PATH}/work/mock-k-cluster/snapshot"
  asked=0
  if [[ -f "${RUN_BASE_PATH}/work/mock-k-cluster/snapshots-asked" ]]; then
    asked=$(<"${RUN_BASE_PATH}/work/mock-k-cluster/snapshots-asked")
  fi
  latest=0
  for round_dir in "${snapshots}"/*; do
    [[ -d "${round_dir}" ]] || continue
    round="$(basename "${round_dir}")"
    if [[ "${round}" -le "${asked}" && "${round}" -gt "${latest}" ]]; then
      latest="${round}"
    fi
  done
  printf '{"apiVersion":"v1","kind":"List","items":['
  separator=""
  for seen_file in "${snapshots}/${latest}"/ReplicaSet-*; do
    [[ -f "${seen_file}" ]] || continue
    printf '%s%s' "${separator}" "$(<"${seen_file}")"
    separator=","
  done
  printf ']}\n'
  exit 0
fi

if [[ "$*" == "get deployments,statefulsets,daemonsets,jobs,pods -o json" ]]; then
  snapshots="${RUN_BASE_PATH}/work/mock-k-cluster/snapshot"
  asked=1
  if [[ -f "${RUN_BASE_PATH}/work/mock-k-cluster/snapshots-asked" ]]; then
    asked=$(( $(<"${RUN_BASE_PATH}/work/mock-k-cluster/snapshots-asked") + 1 ))
  fi
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  echo "${asked}" > "${RUN_BASE_PATH}/work/mock-k-cluster/snapshots-asked"
  fails_file="${RUN_BASE_PATH}/work/mock-k-cluster/snapshot-fails"
  if [[ -f "${fails_file}" ]]; then
    fails_left=$(<"${fails_file}")
    if [[ -z "${fails_left}" || "${fails_left}" -gt 0 ]]; then
      if [[ -n "${fails_left}" ]]; then
        echo "$((fails_left - 1))" > "${fails_file}"
      fi
      echo "Error from server (Forbidden): deployments.apps is forbidden" >&2
      exit 1
    fi
  fi
  latest=0
  for round_dir in "${snapshots}"/*; do
    [[ -d "${round_dir}" ]] || continue
    round="$(basename "${round_dir}")"
    if [[ "${round}" -le "${asked}" && "${round}" -gt "${latest}" ]]; then
      latest="${round}"
    fi
  done
  printf '{"apiVersion":"v1","kind":"List","items":['
  separator=""
  for seen_file in "${snapshots}/${latest}"/*; do
    [[ -f "${seen_file}" ]] || continue
    printf '%s%s' "${separator}" "$(<"${seen_file}")"
    separator=","
  done
  printf ']}\n'
  exit 0
fi

# Return empty for jsonpath queries (oci-images)
if [[ "$*" == *"-o jsonpath"* ]] || [[ "$*" == *"-o go-template"* ]]; then
  exit 0
fi

# A small fake cluster for the scripts that compare a set with the cluster and
# reapply it. An object is kept under the path of the manifest that declares
# it, which is how those scripts address it too (get -f, apply -f). Tests put
# objects in with cluster_holds and cluster_would_make.
cluster="${RUN_BASE_PATH}/work/mock-k-cluster"
manifest=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "-f" ]]; then
    manifest="${argument%/}"
  fi
  previous="${argument}"
done
held="${cluster}/${manifest//\//_}"

# get -f <manifest> -o yaml or -o name: the live object, or NotFound
if [[ "$1" == "get" && ("$*" == *"-o yaml"* || "$*" == *"-o name"*) && -n "${manifest}" ]]; then
  if [[ -f "${cluster}/get-fails" ]]; then
    echo "Error from server (Forbidden): mocks is forbidden" >&2
    exit 1
  fi
  # A Job a test has said disappears once applied
  if [[ -f "${held}" && -f "${held}.gone" ]]; then
    echo "Error from server (NotFound): jobs.batch \"$(basename "${manifest}")\" not found" >&2
    exit 1
  fi
  if [[ -f "${held}" ]]; then
    cat "${held}"
    # A Job a test has given an ending with job_ends: its status, once it has
    # been asked about as many times as the test said it takes
    if [[ -f "${held}.status" ]]; then
      rounds_left=$(<"${held}.status-rounds")
      if [[ "${rounds_left}" -gt 0 ]]; then
        echo "$((rounds_left - 1))" > "${held}.status-rounds"
      else
        cat "${held}.status"
      fi
    fi
    exit 0
  fi
  echo "Error from server (NotFound): mocks \"$(basename "${manifest}")\" not found" >&2
  exit 1
fi

# apply --dry-run=server ... -o yaml: what the object would become. The
# manifest itself unless a test said otherwise.
if [[ "$1" == "apply" && "$*" == *"--dry-run=server"* && "$*" == *"-o yaml"* ]]; then
  # As kubectl words a field manager conflict, advice and all
  if [[ -f "${cluster}/dry-run-fails" ]]; then
    {
      echo "error: Apply failed with 1 conflict: conflict with \"someone-else\" using apps/v1: .spec.replicas"
      echo "Please review the fields above--they currently have other managers. Here"
      echo "are the ways you can resolve this warning:"
      echo "* If you intend to manage all of these fields, please re-run the apply"
      echo "  command with the \`--force-conflicts\` flag."
    } >&2
    exit 1
  fi
  # Any other refusal
  if [[ -f "${cluster}/dry-run-invalid-fails" ]]; then
    echo "The mocks \"$(basename "${manifest}")\" is invalid: spec: Invalid value: field is immutable" >&2
    exit 1
  fi
  if [[ -f "${held}.wanted" ]]; then
    cat "${held}.wanted"
  else
    cat "${manifest}"
  fi
  exit 0
fi

# A real apply puts every manifest it is given into the cluster
if [[ "$1" == "apply" && "$*" != *"--dry-run"* && -n "${manifest}" ]]; then
  if [[ -f "${cluster}/apply-fails" ]]; then
    echo "Apply failed with 1 conflict: conflict with \"someone-else\"" >&2
    exit 1
  fi
  mkdir -p "${cluster}"
  if [[ -d "${manifest}" ]]; then
    while IFS= read -r applied; do
      cp "${applied}" "${cluster}/${applied//\//_}"
    done < <(find "${manifest}" -type f -name '*.yaml')
  elif [[ -f "${manifest}" ]]; then
    cp "${manifest}" "${held}"
  fi
fi

echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k-standard"
  cp "${TEST_MOCK_BIN}/k-standard" "${TEST_MOCK_BIN}/k"
}

# Where the mock k's fake cluster keeps the object a manifest declares
cluster_path() {
  local manifest="$1"
  printf '%s/work/mock-k-cluster/%s' "${RUN_BASE_PATH}" "${manifest//\//_}"
}

# Put an object in the fake cluster as the live form of a manifest. With no
# document it is the manifest as written, which is what the cluster holds
# straight after that manifest was applied.
cluster_holds() {
  local manifest="$1"
  local document="${2:-$1}"
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  cp "${document}" "$(cluster_path "${manifest}")"
}

# Say what a dry-run of a manifest answers, when it is not just the manifest:
# the object as it would be, with whatever other managers own still on it
cluster_would_make() {
  local manifest="$1"
  local document="$2"
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  cp "${document}" "$(cluster_path "${manifest}").wanted"
}

# Put a pod in the fake cluster's namespace: its name, the one label it carries
# (key=value, or none), its phase, then the restart count of each of its
# containers. Its uid is uid-of-<name>. A count written init:<n> is an init container's. No counts at all
# is a pod with no container statuses yet. LIVE_POD_DELETING=true in front
# makes it one that is being deleted.
live_pod() {
  local name="$1"
  local label="$2"
  local phase="$3"
  shift 3

  local labels=""
  if [[ "${label}" != "none" ]]; then
    labels=",\"labels\":{\"${label%%=*}\":\"${label#*=}\"}"
  fi

  local deleting=""
  if [[ "${LIVE_POD_DELETING:-false}" == "true" ]]; then
    deleting=',"deletionTimestamp":"2026-11-23T00:00:00Z"'
  fi

  local containers=""
  local init_containers=""
  local count
  for count in "$@"; do
    if [[ "${count}" == init:* ]]; then
      init_containers+="${init_containers:+,}{\"name\":\"init\",\"restartCount\":${count#init:}}"
    else
      containers+="${containers:+,}{\"name\":\"main\",\"restartCount\":${count}}"
    fi
  done

  local statuses=""
  if [[ -n "${init_containers}" ]]; then
    statuses+=",\"initContainerStatuses\":[${init_containers}]"
  fi
  if [[ -n "${containers}" ]]; then
    statuses+=",\"containerStatuses\":[${containers}]"
  fi

  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster/pods"
  printf '{"metadata":{"name":"%s","uid":"uid-of-%s"%s%s},"status":{"phase":"%s"%s}}' \
    "${name}" "${name}" "${labels}" "${deleting}" "${phase}" "${statuses}" \
    > "${RUN_BASE_PATH}/work/mock-k-cluster/pods/${name}"
}

# Make one kind of call to the fake cluster fail: get, pods, dry-run,
# dry-run-invalid, apply or create. pods is the read of the namespace's pods.
# Both dry-run kinds are the one that asks for the result
# (-o yaml): dry-run is refused as a field manager conflict, dry-run-invalid
# for another reason. install_mock_k_failing_dry_run rejects every dry-run.
cluster_fails() {
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  touch "${RUN_BASE_PATH}/work/mock-k-cluster/$1-fails"
}

# Give a Job an ending, for once its manifest has been applied: Complete or
# Failed, after it has been asked about that many times and found still
# running (none unless said). A Failed one says BackoffLimitExceeded.
job_ends() {
  local manifest="$1"
  local ending="$2"
  local rounds="${3:-0}"
  local held
  held="$(cluster_path "${manifest}")"
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  echo "${rounds}" > "${held}.status-rounds"
  {
    echo "status:"
    echo "  conditions:"
    echo "    - type: ${ending}"
    echo "      status: \"True\""
    if [[ "${ending}" == "Failed" ]]; then
      echo "      reason: BackoffLimitExceeded"
      echo "      message: Job has reached the specified backoff limit"
    fi
  } > "${held}.status"
}

# Make a Job disappear once applied, as its ttlSecondsAfterFinished would
job_vanishes() {
  local manifest="$1"
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  touch "$(cluster_path "${manifest}").gone"
}

# Make a CRD answer "not Established yet" for that many rounds of asking
crd_established_after() {
  local name="$1"
  local rounds="$2"
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-cluster"
  echo "${rounds}" > "${RUN_BASE_PATH}/work/mock-k-cluster/crd-rounds-${name}"
}

# The script a run-platform build generates for a child that brings a role
# binding in its own namespace. This one records how it was called, in
# work/role-binding-commands.log, and refuses if a test asked it to with
# child_role_binding_script_refuses. It also records, in
# work/role-binding-order.log, how many calls k had taken by then, so a test
# can tell what it came before and after.
install_child_role_binding_script() {
  local child="$1"
  cat > "${TEST_MOCK_BIN}/k-${child}-role-binding-only" << MOCK
#!/usr/bin/env bash
echo "k-${child}-role-binding-only \$*" >> "\${RUN_BASE_PATH}/work/role-binding-commands.log"
k_calls=0
if [[ -f "\${RUN_BASE_PATH}/work/k-commands.log" ]]; then
  k_calls=\$(wc -l < "\${RUN_BASE_PATH}/work/k-commands.log")
fi
echo "\$((k_calls)) \$*" >> "\${RUN_BASE_PATH}/work/role-binding-order.log"
if [[ -f "\${RUN_BASE_PATH}/work/role-binding-refused-${child}" ]]; then
  echo "refused: \$*" >&2
  exit 1
fi
echo "mock: k-${child}-role-binding-only \$*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k-${child}-role-binding-only"
}

child_role_binding_script_refuses() {
  touch "${RUN_BASE_PATH}/work/role-binding-refused-$1"
}

# Every dry-run is rejected, everything else behaves as the standard mock does.
# Needs install_mock_k first, for the discovery the kind pre-check reads.
install_mock_k_failing_dry_run() {
  cat > "${TEST_MOCK_BIN}/k" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"--dry-run"* ]]; then
  echo "$@" >> "${RUN_BASE_PATH}/work/k-commands.log"
  echo "validation error" >&2
  exit 1
fi
exec "${TEST_MOCK_BIN}/k-standard" "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/k"
}

# Make a group/version answer discovery with the given kinds. Path is as the
# API serves it: /api/v1 for core, /apis/<group>/<version> for the rest.
serve_discovery() {
  local path="$1"
  shift
  mkdir -p "${RUN_BASE_PATH}/work/mock-k-discovery"
  printf '%s\n' "$*" > "${RUN_BASE_PATH}/work/mock-k-discovery/${path//\//_}"
}

install_mock_kubectl() {
  cat > "${TEST_MOCK_BIN}/kubectl" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${RUN_BASE_PATH}/work/kubectl-commands.log"
echo "mock: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/kubectl"
}

install_mock_notify() {
  # Mock notify-info
  cat > "${TEST_MOCK_BIN}/notify-info" << 'MOCK'
#!/usr/bin/env bash
echo "INFO: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "INFO: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-info"

  # Mock notify-error
  cat > "${TEST_MOCK_BIN}/notify-error" << 'MOCK'
#!/usr/bin/env bash
echo "ERROR: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "ERROR: $*" >&2
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-error"

  # Mock notify-warning
  cat > "${TEST_MOCK_BIN}/notify-warning" << 'MOCK'
#!/usr/bin/env bash
echo "WARNING: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "WARNING: $*" >&2
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-warning"

  # Mock notify-success
  cat > "${TEST_MOCK_BIN}/notify-success" << 'MOCK'
#!/usr/bin/env bash
echo "SUCCESS: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "SUCCESS: $*"
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-success"

  # Mock notify-failure
  cat > "${TEST_MOCK_BIN}/notify-failure" << 'MOCK'
#!/usr/bin/env bash
echo "FAILURE: $*" >> "${RUN_BASE_PATH}/work/notifications.log"
echo "FAILURE: $*" >&2
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-failure"

  # Mock log
  cat > "${TEST_MOCK_BIN}/log" << 'MOCK'
#!/usr/bin/env bash
echo "LOG: $*" >> "${RUN_BASE_PATH}/work/container.log"
MOCK
  chmod +x "${TEST_MOCK_BIN}/log"
}

install_mock_sleep() {
  # Mock sleep: real sleep for 1s only, instant return for >=2s
  local real_sleep
  real_sleep="$(which sleep)"
  cat > "${TEST_MOCK_BIN}/sleep" << MOCK
#!/usr/bin/env bash
arg="\${1:-0}"
int="\${arg%%.*}"
if [[ "\${int}" -ge 2 ]] 2>/dev/null; then
  exit 0
fi
exec "${real_sleep}" "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/sleep"
}

# A date that answers "seconds since the epoch" (date -u +%s) with whatever a
# test last said the time is. Anything else goes to the real date.
install_mock_clock() {
  local real_date
  real_date="$(command -v date)"
  cat > "${TEST_MOCK_BIN}/date" << MOCK
#!/usr/bin/env bash
if [[ "\$*" == "-u +%s" && -f "\${RUN_BASE_PATH}/work/mock-clock" ]]; then
  cat "\${RUN_BASE_PATH}/work/mock-clock"
  exit 0
fi
exec "${real_date}" "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/date"
}

clock_reads() {
  echo "$1" > "${RUN_BASE_PATH}/work/mock-clock"
}

# A sleep that takes no time at all, writes down how long it was asked for in
# work/sleeps.log, and moves the mock clock on by that much. Needs
# install_mock_clock and a clock_reads first.
install_mock_sleep_that_moves_the_clock() {
  cat > "${TEST_MOCK_BIN}/sleep" << 'MOCK'
#!/usr/bin/env bash
echo "$1" >> "${RUN_BASE_PATH}/work/sleeps.log"
echo "$(( $(<"${RUN_BASE_PATH}/work/mock-clock") + $1 ))" > "${RUN_BASE_PATH}/work/mock-clock"
MOCK
  chmod +x "${TEST_MOCK_BIN}/sleep"
}

install_mock_sleep_killer() {
  # Mock sleep that kills parent for >=2s - for breaking infinite loops
  local real_sleep
  real_sleep="$(which sleep)"
  cat > "${TEST_MOCK_BIN}/sleep" << MOCK
#!/usr/bin/env bash
arg="\${1:-0}"
int="\${arg%%.*}"
if [[ "\${int}" -ge 2 ]] 2>/dev/null; then
  kill -KILL "\$PPID" 2>/dev/null
  exit 0
fi
exec "${real_sleep}" "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/sleep"
}

install_mock_interruptible_sleep() {
  # Override interruptible_sleep function - returns immediately
  interruptible_sleep() {
    return 0
  }
  export -f interruptible_sleep
}

install_mock_interruptible_sleep_killer() {
  # Override interruptible_sleep to kill process - for breaking infinite loops
  interruptible_sleep() {
    kill -KILL $$ 2>/dev/null
  }
  export -f interruptible_sleep
}

install_mock_validate_container() {
  cat > "${TEST_MOCK_BIN}/validate-container" << 'MOCK'
#!/usr/bin/env bash
# Mock validation - always passes
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/validate-container"
}

install_mock_validate_token_styles() {
  cat > "${TEST_MOCK_BIN}/validate_token_styles" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/validate_token_styles"
}

install_mock_scan_images() {
  cat > "${TEST_MOCK_BIN}/scan-images" << 'MOCK'
#!/usr/bin/env bash
label="$1"
output_dir="${RUN_BASE_PATH}/work/baseline/oci-images"
mkdir -p "${output_dir}"
touch "${output_dir}/oci-images-${label}-unsorted"
touch "${output_dir}/oci-images-${label}-sorted"
MOCK
  chmod +x "${TEST_MOCK_BIN}/scan-images"
}

# A monitor-environment that finds the environment stable at once, or exits
# with the code given: 63 unrecoverable, 64 out of time, anything else for the
# script itself going wrong
install_mock_monitor_environment() {
  local exit_code="${1:-0}"
  cat > "${TEST_MOCK_BIN}/monitor-environment" << MOCK
#!/usr/bin/env bash
echo "monitor-environment" >> "\${RUN_BASE_PATH}/work/k-commands.log"
exit ${exit_code}
MOCK
  chmod +x "${TEST_MOCK_BIN}/monitor-environment"
}

install_mock_notify_images_changed() {
  cat > "${TEST_MOCK_BIN}/notify-images-changed" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/notify-images-changed"
}

# The cleanup policy ConfigMap as the env or RP build writes it into the image:
# the policy document under one key, the schema it was validated against under
# the other. Both default to the fixtures - a real KaptainPM schema and a
# document that validates against it - and either can be overridden to exercise
# a failure.
write_cleanup_policy_configmap() {
  local document="${1-$(cat "${FIXTURES_DIR}/cleanup/cleanup-policy.yaml")}"
  local schema="${2-$(cat "${FIXTURES_DIR}/cleanup/kaptainpm-schema.json")}"
  local manifest="${RUN_BASE_PATH}/manifests/kaptain-environment-cleanup-policy.yaml"
  mkdir -p "${RUN_BASE_PATH}/manifests"
  {
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: run-test-env-cleanup-policy"
    echo "data:"
    echo "  cleanup-policy.yaml: |"
    sed "s/^/    /" <<< "${document}"
    echo "  kaptainpm-schema.json: |"
    sed "s/^/    /" <<< "${schema}"
  } > "${manifest}"
}

copy_fixture_manifests() {
  cp "${FIXTURES_DIR}/manifests/"* "${TEST_RUN_BASE}/manifests/"
}

copy_fixture_templates() {
  cp "${FIXTURES_DIR}/templates/"* "${TEST_RUN_BASE}/manifests/"
}

copy_fixture_secrets() {
  # Copy secrets to the secrets dir (excluding passphrase)
  for f in "${FIXTURES_DIR}/secrets/"*; do
    [[ -f "$f" ]] || continue
    fname=$(basename "$f")
    if [[ "${fname}" != "environmentPassphrase" ]]; then
      cp "$f" "${TEST_RUN_BASE}/secrets/"
    fi
  done
  # Copy passphrase to the mount secret dir
  cp "${FIXTURES_DIR}/secrets/environmentPassphrase" "${TEST_MOUNT_BASE}/secret/environmentPassphrase"
}
