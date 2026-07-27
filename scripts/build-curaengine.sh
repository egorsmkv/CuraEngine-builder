#!/usr/bin/env bash

set -Eeuo pipefail

CURAENGINE_REPOSITORY="${CURAENGINE_REPOSITORY:-https://github.com/Ultimaker/CuraEngine.git}"
CURAENGINE_REF="${1:-${CURAENGINE_REF:-main}}"
OUTPUT_DIR="${OUTPUT_DIR:-${PWD}/dist}"
BUILDER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: this script builds the Linux release binary and must run on Linux" >&2
    exit 1
fi

for command in git conan cmake ninja patchelf file ldd tar sha256sum readlink; do
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

# CuraEngine 5.13.0 uses std::setprecision without directly including the
# standard <iomanip> header. Some compiler/header combinations expose it
# transitively, but GCC 12 correctly rejects the source. Apply the compatibility
# patch only to affected revisions so it remains safe for future releases.
obj_source="src/utils/OBJ.cpp"
if grep -q 'std::setprecision' "${obj_source}" \
    && ! grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<iomanip>' "${obj_source}"; then
    echo "Applying CuraEngine compatibility patch for <iomanip>"
    git apply "${BUILDER_ROOT}/patches/0001-curaengine-include-iomanip.patch"
fi

parts_view_header="include/geometry/PartsView.h"
if grep -q 'size_t' "${parts_view_header}" \
    && ! grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]*<cstddef>' "${parts_view_header}"; then
    echo "Applying CuraEngine compatibility patch for <cstddef>"
    git apply "${BUILDER_ROOT}/patches/0002-curaengine-include-cstddef.patch"
fi

conan config install https://github.com/Ultimaker/conan-config.git
conan profile detect --force

# Arcus and the plugin host are optional for command-line slicing. Disable them
# and request static Conan dependencies. oneTBB still produces shared libraries,
# so deploy all runtime files for inclusion in the release bundle.
runtime_deploy_dir="${source_dir}/build/runtime-dependencies"
conan install . \
    --build=missing \
    --update \
    --deployer=full_deploy \
    --deployer-folder="${runtime_deploy_dir}" \
    -s build_type=Release \
    -c tools.build:skip_test=True \
    -o "*:shared=False" \
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
bundle_dir="${build_root}/${asset_name}"

mkdir -p "${OUTPUT_DIR}"
mkdir -p "${bundle_dir}/lib"
install -m 0755 "${built_binary}" "${bundle_dir}/CuraEngine"
install -m 0644 LICENSE "${bundle_dir}/LICENSE"

if command -v strip >/dev/null 2>&1; then
    strip "${bundle_dir}/CuraEngine"
fi

# Copy every deployed shared-library name as a real file. This preserves both
# linker names (libfoo.so) and SONAMEs (libfoo.so.N) without fragile symlinks.
while IFS= read -r -d '' library; do
    library_name="$(basename "${library}")"
    destination="${bundle_dir}/lib/${library_name}"
    resolved_library="$(readlink -f "${library}")"

    if [[ -e "${destination}" ]]; then
        if ! cmp -s "${resolved_library}" "${destination}"; then
            echo "error: conflicting runtime libraries named ${library_name}" >&2
            exit 1
        fi
        continue
    fi

    install -m 0755 "${resolved_library}" "${destination}"
done < <(find "${runtime_deploy_dir}" \( -type f -o -type l \) -name '*.so*' -print0)

if ! find "${bundle_dir}/lib" -maxdepth 1 -type f -name '*.so*' -print -quit | grep -q .; then
    echo "error: Conan did not deploy any runtime libraries" >&2
    exit 1
fi

# Make the executable and its libraries relocatable within the extracted bundle.
patchelf --set-rpath '$ORIGIN/lib' "${bundle_dir}/CuraEngine"
while IFS= read -r -d '' library; do
    if file "${library}" | grep -q 'ELF'; then
        patchelf --set-rpath '$ORIGIN' "${library}"
    fi
done < <(find "${bundle_dir}/lib" -maxdepth 1 -type f -name '*.so*' -print0)

"${bundle_dir}/CuraEngine" help >/dev/null
ldd "${bundle_dir}/CuraEngine" >"${build_root}/linked-libraries.txt"
if grep -q 'not found' "${build_root}/linked-libraries.txt"; then
    cat "${build_root}/linked-libraries.txt" >&2
    echo "error: the release bundle has missing runtime libraries" >&2
    exit 1
fi

tar -C "${build_root}" -czf "${OUTPUT_DIR}/${asset_name}.tar.gz" "${asset_name}"
(
    cd "${OUTPUT_DIR}"
    sha256sum "${asset_name}.tar.gz" >"${asset_name}.tar.gz.sha256"
)

popd >/dev/null

echo "Built CuraEngine ${resolved_commit}"
echo "Bundle: ${OUTPUT_DIR}/${asset_name}.tar.gz"
echo "Checksum: ${OUTPUT_DIR}/${asset_name}.tar.gz.sha256"
