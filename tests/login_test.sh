#!/usr/bin/env bash
#
# Tests src/scripts/login.sh against a stand-in crane that records its
# arguments and stdin:
#
#   - the password reaches crane on stdin (--password-stdin), never in its
#     arguments, and is never printed
#   - xtrace that a job turns on for every step (SHELLOPTS, or set -x in
#     $BASH_ENV) is off before the credentials are read
#   - a password of -n reaches crane intact (echo would take it as an option)
#   - an empty username or password stops the step before crane runs: without
#     a username, crane writes a Docker config entry that later reads reject
#   - a registry given as a URL or with a repository path is refused
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it. The circleci CLI is stubbed when it isn't on the PATH.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPT="${ROOT}/src/scripts/login.sh"
SCRIPT_CRANE_LIB=$(cat "${ROOT}/src/scripts/lib/crane.sh")
export SCRIPT_CRANE_LIB

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/no-crane"

# A stand-in for the circleci CLI, which only has to substitute nothing.
if ! command -v circleci > /dev/null 2>&1; then
    printf '#!/bin/sh\ncat\n' > "${WORK}/bin/circleci"
    chmod +x "${WORK}/bin/circleci"
    cp "${WORK}/bin/circleci" "${WORK}/no-crane/circleci"
fi

# Records crane's arguments, one per line, and its stdin.
cat > "${WORK}/bin/crane" << EOF
#!/bin/bash
printf '%s\n' "\$@" > "${WORK}/crane-args"
cat > "${WORK}/crane-stdin"
exit "\${CRANE_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/crane"

TEST_USERNAME="ci-user"
# shellcheck disable=SC2016 # the $ is part of the password, not an expansion
TEST_PASSWORD='s3cret "quoted" $HOME value'

FAILURES=0
RC=0
OUTPUT=""

# run_login [VAR=value ...]: runs login.sh with default parameters,
# overridden by the given assignments, and sets RC and OUTPUT.
run_login() {
    rm -f "${WORK}/crane-args" "${WORK}/crane-stdin"
    OUTPUT=$(env -u BASH_ENV \
        PATH="${WORK}/bin:${PATH}" \
        REGISTRY_USERNAME="${TEST_USERNAME}" \
        REGISTRY_PASSWORD="${TEST_PASSWORD}" \
        PARAM_USERNAME="REGISTRY_USERNAME" \
        PARAM_PASSWORD="REGISTRY_PASSWORD" \
        PARAM_REGISTRY="registry.example:5000" \
        ${@+"$@"} \
        bash "${SCRIPT}" 2>&1)
    RC=$?
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | %s\n' "${OUTPUT}"
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
output_lacks() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
crane_not_run() { [[ ! -e "${WORK}/crane-args" ]]; }
args_lack() { ! grep -qF -- "$1" "${WORK}/crane-args"; }
stdin_is() { [[ -f "${WORK}/crane-stdin" && "$(cat "${WORK}/crane-stdin")" == "$1" ]]; }
args_are() { [[ -f "${WORK}/crane-args" && "$(cat "${WORK}/crane-args")" == "$(printf '%s\n' "$@")" ]]; }

run_login
check "logs in" rc_is_zero
check "runs crane auth login with the username and the password on stdin" \
    args_are auth login --username "${TEST_USERNAME}" --password-stdin -- "registry.example:5000"
check "sends the password on stdin" stdin_is "${TEST_PASSWORD}"
check "keeps the password off crane's command line" args_lack "s3cret"
check "never prints the password" output_lacks "s3cret"
check "names the variables the credentials came from" output_has "Password: from REGISTRY_PASSWORD"

# echo would take a password of -n as its own option and send nothing.
run_login REGISTRY_PASSWORD="-n"
check "logs in with a password of -n" rc_is_zero
check "sends a password of -n on stdin" stdin_is "-n"

run_login SHELLOPTS=xtrace
check "logs in with xtrace turned on for the job" rc_is_zero
check "turns xtrace off before reading the credentials" output_lacks "s3cret"

run_login REGISTRY_USERNAME=""
check "fails when the username is empty" rc_is_nonzero
check "names the empty username variable" output_has "ERROR: The REGISTRY_USERNAME environment variable"
check "does not run crane without a username" crane_not_run

run_login PARAM_PASSWORD="UNSET_TEST_PASSWORD"
check "fails when the password variable is unset" rc_is_nonzero
check "names the empty password variable" output_has "ERROR: The UNSET_TEST_PASSWORD environment variable"
check "does not run crane without a password" crane_not_run

run_login PARAM_USERNAME="not a name"
check "rejects a username parameter that can't name a variable" rc_is_nonzero
check "names the username parameter in the error" output_has "ERROR: username must name an environment variable"

run_login PARAM_REGISTRY="https://registry.example"
check "rejects a registry given as a URL" rc_is_nonzero
check "does not run crane for a URL" crane_not_run

run_login PARAM_REGISTRY="registry.example/myorg"
check "rejects a registry with a repository path" rc_is_nonzero

run_login PARAM_REGISTRY=""
check "rejects an empty registry" rc_is_nonzero
check "says registry is required" output_has "ERROR: registry is required"

run_login CRANE_EXIT=1
check "fails when crane auth login fails" rc_is_nonzero

run_login SCRIPT_CRANE_LIB=""
check "fails without the shared helpers" rc_is_nonzero
check "says the shared helpers are missing" output_has "ERROR: The shared helpers were not loaded"

# Without crane on the PATH, unless a real one is installed there.
NO_CRANE_PATH="${WORK}/no-crane:/usr/local/bin:/usr/bin:/bin"
if PATH="${NO_CRANE_PATH}" command -v crane > /dev/null 2>&1; then
    echo "skip: crane is installed, so the missing-crane error was not checked"
else
    run_login PATH="${NO_CRANE_PATH}"
    check "fails when crane is not installed" rc_is_nonzero
    check "says to run the install command" output_has "Run the install command"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All login tests passed."
