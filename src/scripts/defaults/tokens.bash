#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# tokens.bash - Token configuration validation for deploy context.
#
# TOKEN_NAME_STYLE and TOKEN_DELIMITER_STYLE must be baked into the
# image at build time to match the manifests. This file validates
# they are present and valid rather than providing defaults.
#

# How to handle trailing newlines when reading token value files
CONFIG_VALUE_TRAILING_NEWLINE="${CONFIG_VALUE_TRAILING_NEWLINE:-strip-for-single-line}"

# Hard validation: these must be set in the environment
if [[ -z "${TOKEN_DELIMITER_STYLE:-}" ]]; then
  echo "TOKEN_DELIMITER_STYLE must be set (baked into image at build time)" >&2
  exit 1
fi

if [[ -z "${TOKEN_NAME_STYLE:-}" ]]; then
  echo "TOKEN_NAME_STYLE must be set (baked into image at build time)" >&2
  exit 1
fi
