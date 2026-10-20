#!/bin/bash
#
# Removes registry credentials for the logout command, with crane auth logout,
# which crane 0.15.1 and later have.

set -euo pipefail

if [[ -z "${SCRIPT_CRANE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_CRANE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CRANE_LIB}"

REGISTRY=$(crane_subst "${PARAM_REGISTRY}")

if [[ -z "${REGISTRY}" ]]; then
    echo "ERROR: registry is required. Pass the same host that login took." >&2
    exit 1
fi
crane_require

echo "Removing the credentials for ${REGISTRY} with crane..."
if ! crane auth logout -- "${REGISTRY}"; then
    echo "ERROR: crane auth logout failed. It needs crane 0.15.1 or later." >&2
    exit 1
fi
