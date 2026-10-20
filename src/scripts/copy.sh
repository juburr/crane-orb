#!/bin/bash
#
# Copies an image from one registry or repository to another for the copy
# command, with crane copy. The image's manifests and layers move registry to
# registry, without a Docker daemon.

set -euo pipefail

if [[ -z "${SCRIPT_CRANE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_CRANE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CRANE_LIB}"

SOURCE=$(crane_subst "${PARAM_SOURCE}")
DESTINATION=$(crane_subst "${PARAM_DESTINATION}")
PLATFORM=$(crane_subst "${PARAM_PLATFORM}")
INSECURE=$(crane_bool insecure "${PARAM_INSECURE}")
EXTRA_ARGS=$(crane_subst "${PARAM_EXTRA_ARGS}")

if [[ -z "${SOURCE}" ]]; then
    echo "ERROR: source is required, such as ghcr.io/myorg/myapp:1.0.0." >&2
    exit 1
fi
if [[ -z "${DESTINATION}" ]]; then
    echo "ERROR: destination is required, such as registry.example.com/myapp:1.0.0." >&2
    exit 1
fi
crane_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${CRANE_WORDS[@]+"${CRANE_WORDS[@]}"})
crane_global_args "${PLATFORM}" "${INSECURE}"
crane_require

COPY_ARGS=(copy)
# These arrays can be empty, and bash before 4.4 treats an empty array as
# unset under set -u, so they are expanded only when they have elements.
COPY_ARGS+=(${CRANE_GLOBAL_ARGS[@]+"${CRANE_GLOBAL_ARGS[@]}"})
COPY_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
# After --, a reference that starts with "-" is not read as a flag.
COPY_ARGS+=(-- "${SOURCE}" "${DESTINATION}")

echo "Copying ${SOURCE} to ${DESTINATION} with crane..."
echo "  Platform: ${PLATFORM:-<every platform>}"
echo "  Insecure: ${INSECURE}"
crane "${COPY_ARGS[@]}"
echo "Copied ${SOURCE} to ${DESTINATION}."
