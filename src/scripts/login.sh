#!/bin/bash
#
# Stores registry credentials for the login command, with crane auth login.
# crane writes them where Docker does (~/.docker/config.json), so later crane
# and docker commands use them too. crane does not contact the registry here,
# so wrong credentials only fail the first command that uses them.

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the password.
set +o xtrace

if [[ -z "${SCRIPT_CRANE_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_CRANE_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_CRANE_LIB}"

REGISTRY=$(crane_subst "${PARAM_REGISTRY}")
crane_env_var_name username "${PARAM_USERNAME}"
crane_env_var_name password "${PARAM_PASSWORD}"
USERNAME=${!PARAM_USERNAME:-}
PASSWORD=${!PARAM_PASSWORD:-}

# Removes the credentials from this shell when the step ends, whatever its
# outcome.
cleanup_secrets() {
    unset PASSWORD USERNAME
}
trap cleanup_secrets EXIT

if [[ -z "${REGISTRY}" ]]; then
    echo "ERROR: registry is required, such as ghcr.io or localhost:5000." >&2
    exit 1
fi
if [[ "${REGISTRY}" == *://* || "${REGISTRY}" == */* ]]; then
    echo "ERROR: registry must be a host with an optional port, such as ghcr.io or localhost:5000, not '${REGISTRY}'." >&2
    exit 1
fi
# Without a username, crane stores an entry that crane 0.14.0 and later, and
# docker, reject when they read the Docker config, which breaks every later
# crane command for every registry.
if [[ -z "${USERNAME}" ]]; then
    echo "ERROR: The ${PARAM_USERNAME} environment variable, which username names, is empty or unset." >&2
    echo "  Set it in a context or project environment variable, or pass the name of another variable as username." >&2
    exit 1
fi
if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: The ${PARAM_PASSWORD} environment variable, which password names, is empty or unset." >&2
    echo "  Set it in a context or project environment variable, or pass the name of another variable as password." >&2
    exit 1
fi
crane_require

echo "Storing credentials for ${REGISTRY} with crane..."
echo "  Username: from ${PARAM_USERNAME}"
echo "  Password: from ${PARAM_PASSWORD}"

# The password goes on stdin, never on the command line. printf, not echo:
# echo would take a password of -n or -e as its own option.
printf '%s\n' "${PASSWORD}" | crane auth login --username "${USERNAME}" --password-stdin -- "${REGISTRY}"
