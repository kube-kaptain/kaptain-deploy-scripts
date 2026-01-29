#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# tokens.bash - Token configuration defaults for deploy context.
#
# TOKEN_NAME_STYLE and TOKEN_DELIMITER_STYLE must be baked into the
# image at build time to match the manifests. Checked by validate-container
# at launch time.
#

# How to handle trailing newlines when reading token value files
CONFIG_VALUE_TRAILING_NEWLINE="${CONFIG_VALUE_TRAILING_NEWLINE:-strip-for-single-line}"

# Required - checked by validate-container at launch time
TOKEN_DELIMITER_STYLE="${TOKEN_DELIMITER_STYLE:-}"
TOKEN_NAME_STYLE="${TOKEN_NAME_STYLE:-}"
