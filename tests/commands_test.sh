#!/usr/bin/env bash
#
# Tests src/scripts/copy.sh, digest.sh, tag.sh and logout.sh against a
# stand-in crane that records its arguments, one call per file, and prints a
# reference by digest for crane digest:
#
#   - each command builds exactly the crane arguments expected, with no empty
#     argument where an optional array is empty, even on bash < 4.4
#   - platform and insecure become crane's --platform and --insecure
#   - extra_args and tags split like shell words, and a $(...) or backtick
#     reaches nothing that runs it
#   - digest exports the digest and the reference by digest, shell-quoted, to
#     the variables digest_env_var and digest_ref_env_var name, and refuses
#     output that isn't a reference by sha256 digest
#   - tag runs crane tag once per tag, and checks every tag before writing any
#   - a failed crane fails the step and exports nothing
#   - missing required values stop the step before crane runs
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
SCRIPTS="${ROOT}/src/scripts"
SCRIPT_CRANE_LIB=$(cat "${SCRIPTS}/lib/crane.sh")
export SCRIPT_CRANE_LIB

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/job" "${WORK}/calls"

# A stand-in for the circleci CLI, which only has to substitute nothing.
if ! command -v circleci > /dev/null 2>&1; then
    printf '#!/bin/sh\ncat\n' > "${WORK}/bin/circleci"
    chmod +x "${WORK}/bin/circleci"
fi

DIGEST="sha256:$(printf 'image' | sha256sum | awk '{ print $1 }')"
DIGEST_REF="registry.example/myorg/app@${DIGEST}"

# Records each call's arguments, one per line, in calls/<n>. crane digest
# prints CRANE_DIGEST_OUTPUT, a reference by digest unless a test sets it.
cat > "${WORK}/bin/crane" << EOF
#!/bin/bash
n=\$(find "${WORK}/calls" -type f | wc -l)
printf '%s\n' "\$@" > "${WORK}/calls/\$((n + 1))"
if [[ "\$1" == digest && -z "\${CRANE_EXIT:-}" ]]; then
    printf '%s\n' "\${CRANE_DIGEST_OUTPUT-${DIGEST_REF}}"
fi
exit "\${CRANE_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/crane"

FAILURES=0
RC=0
OUTPUT=""

# run SCRIPT [VAR=value ...]: runs SCRIPT from the job directory with its
# parameters' defaults, overridden by the given assignments, and sets RC and
# OUTPUT. BASH_ENV and the recorded calls start empty.
run() {
    local script=$1
    shift
    rm -f "${WORK}/calls/"*
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${WORK}/job" && env \
        PATH="${WORK}/bin:${PATH}" \
        BASH_ENV="${WORK}/bash_env" \
        "${DEFAULTS[@]}" \
        ${@+"$@"} \
        bash "${SCRIPTS}/${script}" 2>&1)
    RC=$?
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1 call
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | %s\n' "${OUTPUT}"
        for call in "${WORK}/calls/"*; do
            [[ -f "${call}" ]] || continue
            printf '    crane call %s: %s\n' "${call##*/}" "$(tr '\n' ' ' < "${call}")"
        done
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
crane_not_run() { [[ -z "$(ls -A "${WORK}/calls")" ]]; }
calls_are() { [[ "$(find "${WORK}/calls" -type f | wc -l)" -eq "$1" ]]; }
nothing_exported() { [[ ! -s "${WORK}/bash_env" ]]; }
# call_is N ARG...: call N got exactly these arguments.
call_is() {
    local n=$1
    shift
    [[ -f "${WORK}/calls/${n}" && "$(cat "${WORK}/calls/${n}")" == "$(printf '%s\n' "$@")" ]]
}
# exported NAME VALUE: a clean shell that sources BASH_ENV sees NAME=VALUE.
exported() {
    # shellcheck disable=SC2016 # expanded by the clean shell, not here
    [[ "$(env -i bash -c 'source "$1"; printf "%s" "${!2}"' _ "${WORK}/bash_env" "$1")" == "$2" ]]
}

# --- copy
DEFAULTS=(PARAM_SOURCE="ghcr.io/myorg/app:1.0.0" PARAM_DESTINATION="registry.example/app:1.0.0"
    PARAM_PLATFORM="" PARAM_INSECURE="0" PARAM_EXTRA_ARGS="")

run copy.sh
check "copy succeeds" rc_is_zero
check "copy passes no optional flags by default" \
    call_is 1 copy -- "ghcr.io/myorg/app:1.0.0" "registry.example/app:1.0.0"

run copy.sh PARAM_PLATFORM="linux/arm64" PARAM_INSECURE="1" PARAM_EXTRA_ARGS='--jobs 4 --no-clobber'
check "copy with every option succeeds" rc_is_zero
check "copy passes the platform, insecure and extra arguments" \
    call_is 1 copy --platform linux/arm64 --insecure --jobs 4 --no-clobber -- \
    "ghcr.io/myorg/app:1.0.0" "registry.example/app:1.0.0"

run copy.sh PARAM_SOURCE="-oops"
check "copy keeps a source that starts with - after --" \
    call_is 1 copy -- "-oops" "registry.example/app:1.0.0"

# shellcheck disable=SC2016 # the command substitution must reach the script unexpanded
run copy.sh PARAM_EXTRA_ARGS='--jobs $(touch pwned)'
check "copy refuses a command substitution in extra_args" rc_is_nonzero
check "copy explains the command substitution" output_has "ERROR: extra_args could not be split into arguments"
check "copy runs nothing from extra_args" test ! -e "${WORK}/job/pwned"
check "copy does not run crane with unusable extra_args" crane_not_run

run copy.sh PARAM_INSECURE="maybe"
check "copy rejects an insecure that isn't a boolean" rc_is_nonzero
check "copy names insecure in the error" output_has "ERROR: insecure must be true or false"

run copy.sh PARAM_SOURCE=""
check "copy requires a source" rc_is_nonzero
check "copy says source is required" output_has "ERROR: source is required"

run copy.sh PARAM_DESTINATION=""
check "copy requires a destination" rc_is_nonzero
check "copy does not run crane without a destination" crane_not_run

run copy.sh CRANE_EXIT=1
check "copy fails when crane copy fails" rc_is_nonzero

run copy.sh SCRIPT_CRANE_LIB=""
check "copy fails without the shared helpers" rc_is_nonzero
check "copy says the shared helpers are missing" output_has "ERROR: The shared helpers were not loaded"

# --- digest
DEFAULTS=(PARAM_IMAGE="registry.example/myorg/app:1.0.0" PARAM_PLATFORM="" PARAM_INSECURE="0"
    PARAM_EXTRA_ARGS="" PARAM_DIGEST_ENV_VAR="CRANE_DIGEST" PARAM_DIGEST_REF_ENV_VAR="CRANE_DIGEST_REF")

run digest.sh
check "digest succeeds" rc_is_zero
check "digest asks crane for the full reference, with no optional flags" \
    call_is 1 digest --full-ref -- "registry.example/myorg/app:1.0.0"
check "digest exports the digest" exported CRANE_DIGEST "${DIGEST}"
check "digest exports the reference by digest" exported CRANE_DIGEST_REF "${DIGEST_REF}"

run digest.sh PARAM_PLATFORM="linux/amd64" PARAM_INSECURE="1" PARAM_EXTRA_ARGS="-v" \
    PARAM_DIGEST_ENV_VAR="APP_DIGEST" PARAM_DIGEST_REF_ENV_VAR="APP_REF"
check "digest with every option succeeds" rc_is_zero
check "digest passes the platform, insecure and extra arguments" \
    call_is 1 digest --full-ref --platform linux/amd64 --insecure -v -- "registry.example/myorg/app:1.0.0"
check "digest exports to the variables digest_env_var and digest_ref_env_var name" \
    exported APP_REF "${DIGEST_REF}"

run digest.sh CRANE_DIGEST_OUTPUT="${DIGEST}"
check "digest refuses output without a reference" rc_is_nonzero
check "digest says what crane printed" output_has "ERROR: crane digest printed"
check "digest exports nothing for unusable output" nothing_exported

run digest.sh CRANE_DIGEST_OUTPUT="registry.example/app@sha512:abc"
check "digest refuses a digest that isn't sha256" rc_is_nonzero

run digest.sh CRANE_EXIT=1
check "digest fails when crane digest fails" rc_is_nonzero
check "digest exports nothing when crane fails" nothing_exported

run digest.sh PARAM_DIGEST_REF_ENV_VAR="1BAD"
check "digest refuses a digest_ref_env_var that can't name a variable" rc_is_nonzero
check "digest does not run crane with a bad variable name" crane_not_run

run digest.sh PARAM_IMAGE=""
check "digest requires an image" rc_is_nonzero

run digest.sh BASH_ENV=""
check "digest succeeds without BASH_ENV" rc_is_zero
check "digest warns that nothing was exported" output_has "WARN: BASH_ENV is not set"

# --- tag
DEFAULTS=(PARAM_IMAGE="${DIGEST_REF}" PARAM_TAGS=$'1.2.3 latest\nstable' PARAM_INSECURE="0" PARAM_EXTRA_ARGS="")

run tag.sh
check "tag succeeds" rc_is_zero
check "tag runs crane tag once per tag" calls_are 3
check "tag passes the first tag" call_is 1 tag -- "${DIGEST_REF}" 1.2.3
check "tag passes the last tag" call_is 3 tag -- "${DIGEST_REF}" stable

run tag.sh PARAM_TAGS="v1" PARAM_INSECURE="1" PARAM_EXTRA_ARGS="-v"
check "tag passes insecure and extra arguments" call_is 1 tag --insecure -v -- "${DIGEST_REF}" v1

run tag.sh PARAM_TAGS="good registry.example/app:bad"
check "tag refuses a reference where a tag belongs" rc_is_nonzero
check "tag names the bad tag" output_has "ERROR: 'registry.example/app:bad' is not a valid tag"
check "tag writes no tag when one is bad" crane_not_run

run tag.sh PARAM_TAGS="-dash"
check "tag refuses a tag that starts with -" rc_is_nonzero

run tag.sh PARAM_TAGS=" "
check "tag requires tags" rc_is_nonzero
check "tag says tags is required" output_has "ERROR: tags is required"

run tag.sh PARAM_IMAGE=""
check "tag requires an image" rc_is_nonzero

run tag.sh CRANE_EXIT=1
check "tag fails when crane tag fails" rc_is_nonzero
check "tag stops at the first failure" calls_are 1

# --- logout
DEFAULTS=(PARAM_REGISTRY="registry.example:5000")

run logout.sh
check "logout succeeds" rc_is_zero
check "logout runs crane auth logout for the registry" call_is 1 auth logout -- "registry.example:5000"

run logout.sh PARAM_REGISTRY=""
check "logout requires a registry" rc_is_nonzero
check "logout does not run crane without a registry" crane_not_run

run logout.sh CRANE_EXIT=1
check "logout fails when crane auth logout fails" rc_is_nonzero
check "logout names the crane version it needs" output_has "It needs crane 0.15.1 or later"

# --- crane_export
# The digests above need no quoting, so the helper gets a value that does.
# shellcheck disable=SC2016 # the command substitution must reach crane_export unexpanded
HOSTILE='two words $(touch '"${WORK}"'/job/exported-pwned) "quoted"'
: > "${WORK}/bash_env"
OUTPUT=$(BASH_ENV="${WORK}/bash_env" bash -c 'set -euo pipefail; eval "$1"; crane_export HOSTILE_VALUE "$2"' _ \
    "${SCRIPT_CRANE_LIB}" "${HOSTILE}" 2>&1)
RC=$?
check "crane_export writes the value" rc_is_zero
check "crane_export shell-quotes the value" exported HOSTILE_VALUE "${HOSTILE}"
check "crane_export runs nothing in the value" test ! -e "${WORK}/job/exported-pwned"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All copy, digest, tag and logout tests passed."
