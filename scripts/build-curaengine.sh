#!/usr/bin/env bash

set -Eeuo pipefail

CURAENGINE_REPOSITORY="${CURAENGINE_REPOSITORY:-https://github.com/Ultimaker/CuraEngine.git}"
CURAENGINE_REF="${1:-${CURAENGINE_REF:-main}}"
OUTPUT_DIR="${OUTPUT_DIR:-${PWD}/dist}"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: this script builds the Linux release binary and must run on Linux" >&2
    exit 1
fi

for command in git conan cmake ninja; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
done

if [[ -n "${WORK_DIR:-}" ]]; then
    mkdir -p "${WORK_DIR}"
    build_root="$(mktemp -d "${WORK_DIR%/}/curaengine-build.XXXXXX")"
else
    build_root="$(mktemp -d)"
fi

cleanup() {
    rm -rf "${build_root}"
}
trap cleanup EXIT

source_dir="${build_root}/CuraEngine"

echo "Cloning ${CURAENGINE_REPOSITORY}"
git clone --filter=blob:none --no-checkout "${CURAENGINE_REPOSITORY}" "${source_dir}"

echo "Checking out CuraEngine ref ${CURAENGINE_REF}"
if ! git -C "${source_dir}" fetch --depth=1 origin "${CURAENGINE_REF}"; then
    # Builder releases are often named "vX.Y.Z", while CuraEngine tags are "X.Y.Z".
    if [[ "${CURAENGINE_REF}" == v* ]]; then
        CURAENGINE_REF="${CURAENGINE_REF#v}"
        echo "Retrying with CuraEngine ref ${CURAENGINE_REF}"
        git -C "${source_dir}" fetch --depth=1 origin "${CURAENGINE_REF}"
    else
        exit 1
    fi
fi
git -C "${source_dir}" checkout --detach FETCH_HEAD

pushd "${source_dir}" >/dev/null

conan config install https://github.com/Ultimaker/conan-config.git
conan profile detect --force

# Arcus and the plugin host are optional for command-line slicing. Disabling them
# avoids shipping optional shared libraries beside the release executable.
conan install . \
    --build=missing \
    --update \
    -s build_type=Release \
    -c tools.build:skip_test=True \
    -o enable_arcus=False \
    -o enable_plugins=False

cmake --preset conan-release
cmake --build --preset conan-release --parallel

built_binary="${source_dir}/build/Release/CuraEngine"
if [[ ! -x "${built_binary}" ]]; then
    echo "error: expected binary was not produced at ${built_binary}" >&2
    exit 1
fi

resolved_commit="$(git rev-parse --short=12 HEAD)"
safe_ref="$(printf '%s' "${CURAENGINE_REF}" | tr -cs 'A-Za-z0-9._-' '-')"
asset_name="CuraEngine-${safe_ref%-}-ubuntu-22.04-x86_64"

mkdir -p "${OUTPUT_DIR}"
install -m 0755 "${built_binary}" "${OUTPUT_DIR}/${asset_name}"

if command -v strip >/dev/null 2>&1; then
    strip "${OUTPUT_DIR}/${asset_name}"
fi

"${OUTPUT_DIR}/${asset_name}" help >/dev/null
(
    cd "${OUTPUT_DIR}"
    sha256sum "${asset_name}" >"${asset_name}.sha256"
)

popd >/dev/null

echo "Built CuraEngine ${resolved_commit}"
echo "Binary: ${OUTPUT_DIR}/${asset_name}"
echo "Checksum: ${OUTPUT_DIR}/${asset_name}.sha256"
