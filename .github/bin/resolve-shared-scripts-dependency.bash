#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# resolve-shared-scripts-dependency.bash
#
# Extracts shared scripts from the pinned kaptain-shared-scripts image and writes
# them into src/scripts/. Fails if the result differs from what is already committed,
# ensuring vendored files always match the pinned version.
#
# Run locally to update vendored files after bumping KaptainSharedScriptsVersion.
# Run in CI (pre-tagging tests) as an integrity check.
#
# Requires: docker (or IMAGE_BUILD_COMMAND if set), git, OUTPUT_SUB_PATH
#
set -euo pipefail

BUILD_SCRIPTS_TAG="1.0.86"

if [[ -n "${KAPTAIN_BUILD_SCRIPTS_REPO_ROOT:-}" ]]; then
  BUILD_SCRIPTS_WORKTREE="${KAPTAIN_BUILD_SCRIPTS_REPO_ROOT}/kaptain-out/build-scripts"
  git -C "${KAPTAIN_BUILD_SCRIPTS_REPO_ROOT}" fetch origin
  git -C "${KAPTAIN_BUILD_SCRIPTS_REPO_ROOT}" worktree add kaptain-out/build-scripts "${BUILD_SCRIPTS_TAG}"
  trap 'git -C "${KAPTAIN_BUILD_SCRIPTS_REPO_ROOT}" worktree remove --force kaptain-out/build-scripts 2>/dev/null || true' EXIT
  EXTRACT_SCRIPT="${BUILD_SCRIPTS_WORKTREE}/src/scripts/util/extract-oci-image"
else
  EXTRACT_SCRIPT=".github/buildon-github-actions/src/scripts/util/extract-oci-image"
fi

VERSION_FILE="src/config/KaptainSharedScriptsVersion"

IMAGE_BUILD_COMMAND="${IMAGE_BUILD_COMMAND:-docker}"
export IMAGE_BUILD_COMMAND

OUTPUT_SUB_PATH="${OUTPUT_SUB_PATH:-target}"
EXTRACT_DIR="${OUTPUT_SUB_PATH}/shared-scripts/all"

VERSION="$(cat "${VERSION_FILE}")"
IMAGE="ghcr.io/kube-kaptain/kaptain/kaptain-shared-scripts:${VERSION}"

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"

echo "Resolving shared scripts dependency: ${IMAGE}"

"${EXTRACT_SCRIPT}" "${IMAGE}" "${EXTRACT_DIR}"

EXTRACTED="${EXTRACT_DIR}/scripts"

# Subtractive replacement for plugin directories
rm -rf "src/scripts/plugins/token-name-validators"
rm -rf "src/scripts/plugins/token-substitution-providers"
cp -a "${EXTRACTED}/plugins/token-name-validators" "src/scripts/plugins/"
cp -a "${EXTRACTED}/plugins/token-substitution-providers" "src/scripts/plugins/"

# File replacement for individual shared files
cp "${EXTRACTED}/lib/token-format.bash" "src/scripts/lib/"
cp "${EXTRACTED}/lib/prepare-token-name-and-value.bash" "src/scripts/lib/"
cp "${EXTRACTED}/util/substitute-tokens-from-dir" "src/scripts/util/"

echo "Shared scripts written. Verifying against committed files..."

if ! git diff --quiet; then
  echo "ERROR: The following files differ after dependency resolution:"
  echo ""
  git diff --name-only
  echo ""
  echo "ERROR: In repo shared scripts do not match those from ${IMAGE}"
  echo "  Run .github/bin/resolve-shared-scripts-dependency.bash locally and review/commit the changes."
  exit 1
fi

echo "Shared scripts verified: identical to ${IMAGE}"
