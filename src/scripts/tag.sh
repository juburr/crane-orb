#!/bin/bash
#
# Adds tags to an image in its registry for the tag command, with crane tag,
# which writes the image's existing manifest under each new tag without
# pulling or pushing any layers.

set -euo pipefail

if [[ -z "${SCRIPT_CRANE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_CRANE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CRANE_LIB}"

IMAGE=$(crane_subst "${PARAM_IMAGE}")
TAGS=$(crane_subst "${PARAM_TAGS}")
INSECURE=$(crane_bool insecure "${PARAM_INSECURE}")
EXTRA_ARGS=$(crane_subst "${PARAM_EXTRA_ARGS}")

if [[ -z "${IMAGE}" ]]; then
    echo "ERROR: image is required, such as ghcr.io/myorg/myapp@sha256:<digest>." >&2
    exit 1
fi
crane_words tags "${TAGS}"
TAG_LIST=(${CRANE_WORDS[@]+"${CRANE_WORDS[@]}"})
if [[ "${#TAG_LIST[@]}" -eq 0 ]]; then
    echo "ERROR: tags is required: the tags to add, separated by spaces or newlines." >&2
    exit 1
fi
# crane tag takes a tag, not a reference, and every tag is checked before any
# is written.
for tag in "${TAG_LIST[@]}"; do
    if [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
        echo "ERROR: '${tag}' is not a valid tag: up to 128 letters, digits, _, . and -, not starting with . or -." >&2
        exit 1
    fi
done
crane_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${CRANE_WORDS[@]+"${CRANE_WORDS[@]}"})
crane_global_args "" "${INSECURE}"
crane_require

echo "Tagging ${IMAGE} with crane..."
echo "  Tags: ${TAG_LIST[*]}"
echo "  Insecure: ${INSECURE}"
for tag in "${TAG_LIST[@]}"; do
    TAG_ARGS=(tag)
    # These arrays can be empty, and bash before 4.4 treats an empty array as
    # unset under set -u, so they are expanded only when they have elements.
    TAG_ARGS+=(${CRANE_GLOBAL_ARGS[@]+"${CRANE_GLOBAL_ARGS[@]}"})
    TAG_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
    TAG_ARGS+=(-- "${IMAGE}" "${tag}")
    crane "${TAG_ARGS[@]}"
done
echo "Tagged ${IMAGE} as ${TAG_LIST[*]}."
