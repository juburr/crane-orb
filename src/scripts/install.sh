#!/bin/bash
#
# Installs crane for the install command: the Linux amd64 or arm64 build that
# matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (crane only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing crane needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="crane-orb"
TOOL_NAME="crane"
TOOL_BINARY="crane"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download. The archive
# holds crane, gcrane and krane; only crane is installed.
tool_asset_name() {
    case "$2" in
        amd64) printf 'go-containerregistry_Linux_x86_64.tar.gz\n' ;;
        arm64) printf 'go-containerregistry_Linux_arm64.tar.gz\n' ;;
    esac
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf 'https://github.com/google/go-containerregistry/releases/download/v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'crane\n'
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    "$1" version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["0.22.1/amd64"]="96e59ce550320453161526dab8bec5b6be749158e0c987ca6ffbf47801fa6cd41f870913059dbe80aa09c22bcd45ac35fde2b556bf6eaf40e537c80d2e3a3d9f"
    ["0.22.1/arm64"]="7df144eebf77fa9bfce7202b1426b6d0dbb714621284e058364ffa106d4f1702e3484252d64c9787f7c136ba0fddab0f0a02d4cd9c69144d6b0d7bd6823a483b"
    ["0.22.0/amd64"]="7ec9dfcd5ba6eeedefef5155cf46fbe2e584dbb880ccd5be3c30d4c0b7199e9013b0f1f54f8c7626a74ac4468fa751b71c699ef91c415eabb29b6fdf41751456"
    ["0.22.0/arm64"]="2674e94e116dc31a07e6c29f041ff42bda9c65f908650e5c6c34988e574c85dfeb6a0f4abca5ddca530987ef795149df4e9f73f1183af4ea4663390b4f6e1dcd"
    ["0.21.9/amd64"]="f50512bc003e2d3159cacbff262f533a9b7e51bc81dea0b84d75370e179500a2bc21d7ac56afa267af1de313c4508f285811de2ee80420a86bebebd12f5801b4"
    ["0.21.9/arm64"]="a48d31e1fe5717fa3371d0c5d0a0f609b5ca0bbb09c35e44f8f99ffded652e05b99fb06ae0f97b6e9d42c7dadd134c83a7cc42508a41b1e63805959649a92d4f"
    ["0.21.8/amd64"]="1feb74089629e879183460fe34394ed0afb2fa3abc17a01c92e26945c3074beba0c12759bf8a7d13ff80b23f1c56b083c795dbb3cb29ee925f89180817603009"
    ["0.21.8/arm64"]="fecf5153f68e5c2e4b73b562317a36b10bda8ef83ca78bae86db0b86e91e134550163e0acc19f9593c5036083c05dd0d85233d9664abf0477f8f6f92d1400ffd"
    ["0.21.7/amd64"]="bece6bb6b6f3d513d55e299db03036bd3ceefcbee9ab7d0135f76ec0f96373b6d1baf757c321d3241ae8c22dd1dfd914f8e25743a1b5e860ad880db9714ce3ad"
    ["0.21.7/arm64"]="6372166120471afb2de302f20ed28ef0b970fa97b4f29362921db64d3861c5841051283fdf737a4ae9225c021b5c5ab2ec55ee7a8192bd5d32e2369b5a36b072"
    ["0.21.6/amd64"]="a0faf859fa0083d0309d6eed107cd729c287e309f8b6944f2502eee4d6eb2aed0249aee950266b04d8e960548f28685ff8c55a99f25be6b6740a2fef6f433237"
    ["0.21.6/arm64"]="b1980600d82ba842f79e274f29173c536c731585bf363595c58d9c5f12ba6fca759abcec2a6ae3534fc0819bee320af74708aa8b245a745aabecaf1d83e46bf5"
    ["0.21.5/amd64"]="3f26419de913eb8c85d96dc6bf1ab06d205ec355d057c3693ff312f48ad51af2b72fa3f5736c208a96d9069c81fc598aa683816af130642fe4b57d7f6f1c4852"
    ["0.21.5/arm64"]="4e6661c16ed7c2a6c9e19306e4b4209903a1528eef6646dce5b1d2ac848b100a8596b2cf644d7d4a581344c7db27de8d40e366f03d821bfcbf087c0a455d2dca"
    ["0.21.4/amd64"]="9f2ea4333115a567ac5dafcb3b0f59245a9f5d0cc51a899fb1dabd24a657b33168f8778b309cf7223a4d823d73575bcbd0e7e90629fc893755ab16c9e641a3c9"
    ["0.21.4/arm64"]="e6f86fc9279f8fd388618f566c23f97f9eb67bc1861b913121b64bcf6603265c8de2ee466cd0f999ad35e0a201dc51878e7b5fad6109f2b4c1be802061d37997"
    ["0.21.3/amd64"]="a470756422a719d457ee5c417d9438bb7faf0b8a8a72377810970c611b48716f91ccac1344fee265f9ed7eea1307def9ee7a4161faf4627e60baabd3357717f0"
    ["0.21.3/arm64"]="0c195a62f095aa6c89776fe2d4b91c8db932c87ac2cac41f8132e18f10dd71e4011c20806e76fd694b570fe8133e9dfb9ac0f80d6a43cdcbc4786d858452ba33"
    ["0.21.2/amd64"]="64ad6156a954a109a91417545c4628fa2d36b316ce6d2d3faaef6fb3dcd5f6d5805f863bf2767154d01a0fff8969b4f72581bc2ac90e7855a6d5f54d0ac154aa"
    ["0.21.2/arm64"]="50f16977b5222af221ab88b1adf6c4c13d4b074b31c6fc3cd98e62548d195271b0d98a9f702edabc9522ebc873e24affad427757acb17002842c62876e7e0b96"
    ["0.21.1/amd64"]="999d573dee0941bd1210b6be5a52d56e3d45e8c79e67b5d0f4413f03205f0efdb5bb8c6436a59756d3bb7afbb9211fce21579f0b970287ddfd4b847ebe6d7da0"
    ["0.21.1/arm64"]="4526d14f81ae42239908e06309c829bf0ceb86af1b3507725a01dd619d267d1903e3b8a7f94704ee0da5e164e6fc6f1dd70e9cd37b14152b38aeea78a548e1ab"
    ["0.21.0/amd64"]="c8ddacd6db731de998c00a96bfdd5ce0cf003bdcd1811bba25e77a55eb0b24cb3ba39c360c3924438640f05b2b6833a75e8959cbe07b7493e16eeba51547d351"
    ["0.21.0/arm64"]="e6ed2d9dea38ff22a5b30244d6bf4c94eab4c8981fae8b8b4298076724df3f756c556cc4f7f8bb8c6c2da0ff2c84b94ad27213751d381ea8edff2696c179601c"
    ["0.20.7/amd64"]="f3454043faed6383cef0305eb4ee4322b2cbcb3aa2d75b9dfb0c2ec8535fd4d381cfd6a0ad20117feec2505d9b13e6f62e7d7cc9cddfbeb2763dfb9ccb2e667c"
    ["0.20.7/arm64"]="1b923ba17f5b06f7449befa19e8d15581a2c9ecc373ecb3e121a7663d7e990ca5ab2dc89715f07fa864f80bb7e17361df7de52a991a9f3ecfacbf9f3d8c80c95"
    ["0.20.6/amd64"]="219fc2ae8b69572596dccc9c70e8e2c9eb888ced51b0d921b8bc59020c2675a3d2ae25346f5bdb59d5a16a5019b3de766504118b047ae2cc5abf1467f829ea52"
    ["0.20.6/arm64"]="3e3211be4e36290e6c594d59c31c0e284514d9e29b14858d625f577ee313fa1da97bf68f0be4d4c7aed7cd342a35fbde41821a304523745bbf1d009b41563eee"
    ["0.20.5/amd64"]="57525e74f7c0a9b5103c86f40fbe50de4313ec5a36f9ebb7bf9f8e00c4eee780e8d7b0f7dc50829ef777a5b55f36249638bf463f75e8cdbe8410f34ebcdd58db"
    ["0.20.5/arm64"]="6f6fb6b1ed5703ed392c1866b00b597febe9f26b655d1c1af5a6194a1f78ab1a1adcec4ed24b7a897edee5a45c01fff22ca7907187af2c7a3a097d12cbcfce1a"
    ["0.20.4/amd64"]="3363742f88d36b4d87c805ca95a509d8d28e23df899fd58a3f341aeccaf33bd72fb2804309d0d25eb14a57db0e01f6b571470c64ea2cbec0ad536dce9cbe1254"
    ["0.20.4/arm64"]="326b510cd97513426b380888ca953308bc7640887a7d88f8e54c4167e9a2a0f42c0415225395be408be1e010a33ca5d69106c559914801c89acc7236445b6992"
    ["0.20.3/amd64"]="58c8649c76d0a7a0c150f0f660b4fc20d188c65d63f6fb6dd91dc3a3e58bf3b476bb80681439598a02357804eb1c6a5fd2d25cfa5862ec6b49bf7d989ee8dd2b"
    ["0.20.3/arm64"]="d7249750d435817ab8b997b44d5465eecf4602ae270ea26f171a5028648381400b1c1cd4ea0ee66753c0c09d90b55bba81f571c974794d83c12f4472dd587a96"
    ["0.20.2/amd64"]="e8b216b6367e72aef9cac6cc623bb7e28f46ffae2d8c8c823f1d07e6bc2fd819423c0e00e22e7f551e29fe79f552daea4dfaf73ac6dc4f273d6017f83e793f63"
    ["0.20.2/arm64"]="209f6c281d0d1c1bc0d27c3d539a6426b9d1b9bc1959872629a18adc0c3da8a37b0124ea56425e4937965123cec3af8edf8b8337babb26fc129d1fc98567341a"
    ["0.20.1/amd64"]="78445bb5581b8db7d63e96bdb61f3f20b665a747a91b7bc76d8856339f4f2a99116234d3d7ba6a2c116982792fdc09e6b94ce5b0e4d429bf3991c448e670d64b"
    ["0.20.1/arm64"]="3d94308ca0764573d82cfa315fb6743bcc61fda30d5e90f32c39aa720c6b60ebead830e8c76c8068a52a55f2b9d3b85c7d89d4a0c04365cc47b8800cfd8e3f5d"
    ["0.20.0/amd64"]="40363325bb2caf5b084008f7fda23008ad384dfddaca6eb5359722c7611f226d17ab1925ef81dea896d637136da1860da2eb1ce6ba37e6b2d6b732e50920da45"
    ["0.20.0/arm64"]="20c79db02198db2424b11efb2aa648a27576f2d3d5929dee674cf7abaf44e8b414f55023b97d00787d09037033302b08e9b7546d1c901def43cb1a1db4d19f29"
    ["0.19.2/amd64"]="c201c4dd496082e5c10ba7753ef6cfee2e07f1f82b9dfc9c81446e216d276ce937c72061da1593514dfd9197bda269efa76954dc35eabaeb87d5ca00f2908ce8"
    ["0.19.2/arm64"]="6bdc1728aeeb049bb13ec7d05fd70a46d4466584f1c06e71fdda428cfc7de3f9cb2373685743ad00c42750458c36ada3976774c60f72e29f906da3605eb83699"
    ["0.19.1/amd64"]="b96cf4b977ad869be57b123373bd56a2c3cec3240535c69bedbb362141caea256e56127663cccff308a0bddf812c0748a718ef26c525c339747996d67b8c79e7"
    ["0.19.1/arm64"]="cf060a720e477a3a176c51ef6df99a1875ec5231f02d349873a221112af8c3b921065fa17177bc169551a042af5773cc7f3603b4dbe43bec0369113d209048e4"
    ["0.19.0/amd64"]="d28ed1caa520953a3025e43511d81a19c8197c5c84659adeee4f46ee56f0e01fade3976f97dca16de0a58d99d4c4e9271a0b939b5288eea4c98ce7a7fdfb43b2"
    ["0.19.0/arm64"]="d0b4152109a38b8732b98519504948a044ad988fcba8dad2c59a666014a5d977129af23328cfeb448252043126b864686a4f3978c44905e1e65c035f613ec75b"
    ["0.18.0/amd64"]="a827e494bf589a25a64217562a2bc257943bd987e7040f7430d4743693255fc217edb187f7340f60cdee3dd2c08447c332c801db0446fbbc68fd103734ce4e03"
    ["0.18.0/arm64"]="5853316e7bd92cf68460ee388299f6df9834f769ef8bd10354cf20db5f38aeb71623f1fc078478c09003cab0a3801509b04d8395927e5737c2437406b928b79d"
    ["0.17.0/amd64"]="3a971de329540f10d4df37dcc11e1bde9f74e55d1685bbcabcb1c67befa572744a709ed746487a3f48900380074fb3cdb4ce63940b3d8636fc2deccb7d76cf48"
    ["0.17.0/arm64"]="ba69783fe9ffd537020ae7db41f6676a9c86fa5c0cbf46250720eea94899a6af19805c5245d390035dd0dee20dcf25b9371ecab861d1b2045aa86607a80e3e0d"
    ["0.16.1/amd64"]="a02caee820fe39e429672b23f30f773cff58f54d5d3454912c313c0f7758f5f28626a88054a4c2de37643e2b69a692c462e22ddd23adcd6c3c61bb514689d402"
    ["0.16.1/arm64"]="50af2b87cdb3dfb4c5db9429e7a635f2fbf80205d3d121788e714f796e9a9071e1bee101af478e367f79b5190532c3169826e8dce4b6cac7b007b2a1b4e16bae"
    ["0.15.2/amd64"]="4cba36128e25ff49f477a430301bee85dd8830c5839713f1e8788a6ecd2cc61be4b464593b47a594f1bcd8285391a30823d129072cfdf96105274596ff7f3d57"
    ["0.15.2/arm64"]="92a40a21519945ad9caf1136150fbb2775d3daed01d812fc92baf838af4f8b750a9a7fcefcf1c4a5ee52571be2254962d21960be15d70550e86aaa697a7a324a"
    ["0.15.1/amd64"]="b7925ee782dc97179ec89dbbd61e8a6b2d0539d8bfe32b581e28a966e6cbee43a237813b4dd6819e5e4771d0f9cc8eef4924eb6479ea20689d37226d9f3308ad"
    ["0.15.1/arm64"]="e50b8bb40424d7b997b466b2245467c427ad8cf3814ea422ab2df29778d5e6aa50e09b0fdbd412ab951240f1b8d1e4a16ea17a0b965f6d213709be86163e0d69"
    ["0.14.0/amd64"]="2132bd17217ab78e35ebc364dbd30146af5aa1ff4b47d3a8d5f37e7387ec92c6d140ceeb3e33f350823156f356dadc7f1cdc581a8fd40d71999a2f31ca5bd68d"
    ["0.14.0/arm64"]="bf4432d5896871f39d8ef8952341f32b4404b805ee58b3dff9e261975cfab21b71bbc5bd6d7017e11e41724630f29dcb90170ce61dcec78fefe6da2d9a70c164"
    ["0.13.0/amd64"]="b112d1cc6ad333c0bdce568c0737cabd8e065a81e3aff42326e66a078703b8ca9675233cd4cdc969409aa2759de9876695936fad8df59c53c32596383c480be1"
    ["0.13.0/arm64"]="613748b2f7ac2a151f9dcc65f96844f536708a96fa06066745c64d33455d834b387eac435a6922af2809b3ad449c8edf3b46b76d3d9a4f30763d35c3005af265"
)
# <<< checksum table <<<

orb_install_main
