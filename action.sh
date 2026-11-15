#!/usr/bin/env bash

# action.sh: run zizmor from a hash-verified wheel

set -eu

dbg() {
    echo "::debug::${*}"
}

warn() {
    echo "::warning::${*}"
}

err() {
    echo "::error::${*}"
}

die() {
  err "${*}"
  exit 1
}

installed() {
    command -v "${1}" >/dev/null 2>&1
}

output() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

installed python3 || die "Cannot run this action without Python"

[[ "${RUNNER_OS}" != "Linux" ]] && warn "Unsupported runner OS: ${RUNNER_OS}"

output="${RUNNER_TEMP}/zizmor"

version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+((a|b|rc)[0-9]+)?(\.dev[0-9]+)?$'

# `latest` and `prerelease` select the requirements compiled from their groups.
# Like exact versions, they are pinned in this action's own tree.
case "${GHA_ZIZMOR_VERSION}" in
    latest|"")
        zizmor_version="latest"
        ;;
    prerelease)
        zizmor_version="prerelease"
        ;;
    *)
        [[ "${GHA_ZIZMOR_VERSION}" =~ $version_regex ]] \
            || die "'version' must be 'latest', 'prerelease', or an exact X.Y.Z version (optionally with a prerelease suffix)"
        zizmor_version="${GHA_ZIZMOR_VERSION#v}"
        ;;
esac

arguments=()
arguments+=("--persona=${GHA_ZIZMOR_PERSONA}")

if [[ "${GHA_ZIZMOR_ADVANCED_SECURITY}" == "true" && "${GHA_ZIZMOR_ANNOTATIONS}" == "true" ]]; then
    err "Mutually exclusive options: 'advanced-security: true' and 'annotations: true'"
    die "If you meant to enable 'annotations: true', you must explicitly set 'advanced-security: false'"
fi

if [[ "${GHA_ZIZMOR_ADVANCED_SECURITY}" == "true" ]]; then
    arguments+=("--format=sarif")
    output "sarif-file" "${output}"
elif [[ "${GHA_ZIZMOR_ANNOTATIONS}" == "true" ]]; then
    arguments+=("--format=github")
fi

[[ -n "${GHA_ZIZMOR_COLLECT}" ]] && arguments+=("--collect=${GHA_ZIZMOR_COLLECT}")
[[ "${GHA_ZIZMOR_ONLINE_AUDITS}" == "true" ]] || arguments+=("--no-online-audits")
[[ -n "${GHA_ZIZMOR_MIN_SEVERITY}" ]] && arguments+=("--min-severity=${GHA_ZIZMOR_MIN_SEVERITY}")
[[ -n "${GHA_ZIZMOR_MIN_CONFIDENCE}" ]] && arguments+=("--min-confidence=${GHA_ZIZMOR_MIN_CONFIDENCE}")
[[ "${GHA_ZIZMOR_COLOR}" == "true" ]] && arguments+=("--color=always") || arguments+=("--color=never")

if [[ -n "${GHA_ZIZMOR_CONFIG:-}" ]]; then
    arguments+=("--config=${GHA_ZIZMOR_CONFIG}")
fi

lockfile="${GITHUB_ACTION_PATH}/support/locks/zizmor-${zizmor_version}.txt"
[[ -f "${lockfile}" ]] \
    || die "Unknown version ${zizmor_version}; was it released after this action?"

# The generated requirements start with the exact zizmor pin, including
# for the aliases. Read it to locate the executable inside the wheel.
read -r requirement _ < "${lockfile}"
[[ "${requirement}" == zizmor==* ]] || die "Missing zizmor pin in ${lockfile}"
zizmor_version="${requirement#zizmor==}"

# The lock pins every wheel for this version by hash, so `--require-hashes`
# gives us the same guarantee the pinned container digests used to: pip picks
# the wheel matching the runner and verifies it against that set.
wheeldir="${RUNNER_TEMP}/zizmor-wheel"
rm -rf "${wheeldir}"
mkdir -p "${wheeldir}"

python3 -m pip download \
    --quiet --no-input --disable-pip-version-check \
    --only-binary=:all: \
    --python-version=3.11 \
    --no-deps \
    --require-hashes \
    --dest "${wheeldir}" \
    --requirement "${lockfile}"

wheels=("${wheeldir}"/*.whl)
[[ -f "${wheels[0]}" ]] || die "No zizmor ${zizmor_version} wheel for this runner"

# Wheels are just ZIPs, and zizmor's contains nothing but its executable, so
# unpacking one is the whole installation: no environment to create or remove.
python3 -m zipfile --extract "${wheels[0]}" "${wheeldir}/unpacked"

zizmor="${wheeldir}/unpacked/zizmor-${zizmor_version}.data/scripts/zizmor"
[[ -f "${zizmor}" ]] || zizmor="${zizmor}.exe"
[[ -f "${zizmor}" ]] || die "Wheel for zizmor ${zizmor_version} contains no executable"

# ZIPs carry no permission bits that `zipfile` restores.
chmod +x "${zizmor}"

# Notes:
# - We run from ${GITHUB_WORKSPACE}, so that user inputs like '.' resolve
#   correctly.
# - We pass the GitHub token as an environment variable so that zizmor
#   can run online audits/perform online collection if requested.
# - ${GHA_ZIZMOR_INPUTS} holds one input per line. We put them after `--`
#   so that an input can't be interpreted as one or more flags.
cd "${GITHUB_WORKSPACE}"

# zizmor takes one INPUT argv element per input, but a composite action's
# input arrives as a single string, so split it into one element per line.
# Reading without `IFS=` trims the indentation a YAML block scalar leaves on
# each line, while keeping any spaces inside a line.
input_lines=()
while read -r line; do
    if [[ -n "${line}" ]]; then
        input_lines+=("${line}")
    fi
done <<< "${GHA_ZIZMOR_INPUTS}"

[[ "${#input_lines[@]}" -gt 0 ]] || die "'inputs' must contain at least one input"

# Expand each line as a glob. Expanding here, instead of letting the shell do
# it, keeps `*` and `**` meaning the same thing on every runner: otherwise the
# shell's word-splitting and globstar settings decide what an input means, so
# the same workflow can behave differently on a macOS runner than on Linux.
# A pattern that matches nothing is passed through unchanged, so zizmor
# reports it instead of the run quietly auditing less than was asked for.
inputs_file="${RUNNER_TEMP}/zizmor-inputs"
python3 - "${input_lines[@]}" > "${inputs_file}" <<'PY'
import glob
import sys

for pattern in sys.argv[1:]:
    for match in sorted(glob.glob(pattern, recursive=True)) or [pattern]:
        print(match)
PY

zizmor_inputs=()
while IFS= read -r line; do
    zizmor_inputs+=("${line}")
done < "${inputs_file}"

# Every pattern contributes at least one argument: a glob that matches
# nothing falls back to the pattern itself, so this array is never empty.
GH_TOKEN="${GHA_ZIZMOR_TOKEN}" "${zizmor}" \
    "${arguments[@]}" \
    -- \
    "${zizmor_inputs[@]}" \
        | tee "${output}"

exitcode="${PIPESTATUS[0]}"
dbg "zizmor exited with code ${exitcode}"

if [[ "${exitcode}" -eq 3 ]]; then
    warn "No inputs were collected by zizmor"
    [[ "${GHA_ZIZMOR_FAIL_ON_NO_INPUTS}" = "false" ]] && exit 0
fi

exit "${exitcode}"
