#!/bin/bash
#
# Reads an image's digest from its registry for the digest command, with
# crane digest, and exports the digest and the image's reference by digest
# for later steps.

set -euo pipefail

if [[ -z "${SCRIPT_CRANE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_CRANE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CRANE_LIB}"

IMAGE=$(crane_subst "${PARAM_IMAGE}")
PLATFORM=$(crane_subst "${PARAM_PLATFORM}")
INSECURE=$(crane_bool insecure "${PARAM_INSECURE}")
EXTRA_ARGS=$(crane_subst "${PARAM_EXTRA_ARGS}")
crane_env_var_name digest_env_var "${PARAM_DIGEST_ENV_VAR}"
crane_env_var_name digest_ref_env_var "${PARAM_DIGEST_REF_ENV_VAR}"

if [[ -z "${IMAGE}" ]]; then
    echo "ERROR: image is required, such as ghcr.io/myorg/myapp:1.0.0." >&2
    exit 1
fi
crane_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${CRANE_WORDS[@]+"${CRANE_WORDS[@]}"})
crane_global_args "${PLATFORM}" "${INSECURE}"
crane_require

DIGEST_ARGS=(digest --full-ref)
# These arrays can be empty, and bash before 4.4 treats an empty array as
# unset under set -u, so they are expanded only when they have elements.
DIGEST_ARGS+=(${CRANE_GLOBAL_ARGS[@]+"${CRANE_GLOBAL_ARGS[@]}"})
DIGEST_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
# After --, a reference that starts with "-" is not read as a flag.
DIGEST_ARGS+=(-- "${IMAGE}")

echo "Reading the digest of ${IMAGE} with crane..."
echo "  Platform: ${PLATFORM:-<the image as tagged>}"
echo "  Insecure: ${INSECURE}"
# One call gives both values, so they always describe the same manifest.
DIGEST_REF=$(crane "${DIGEST_ARGS[@]}")
DIGEST=${DIGEST_REF##*@}
if [[ "${DIGEST_REF}" != *@* || ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: crane digest printed '${DIGEST_REF}', not a reference by sha256 digest." >&2
    exit 1
fi

echo "  Digest: ${DIGEST}"
echo "  Reference: ${DIGEST_REF}"
crane_export "${PARAM_DIGEST_ENV_VAR}" "${DIGEST}"
crane_export "${PARAM_DIGEST_REF_ENV_VAR}" "${DIGEST_REF}"
echo "Exported ${PARAM_DIGEST_ENV_VAR} and ${PARAM_DIGEST_REF_ENV_VAR} for later steps."
