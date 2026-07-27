# CuraEngine Ubuntu 22.04 builder

This repository builds the open-source
[UltiMaker CuraEngine](https://github.com/Ultimaker/CuraEngine) command-line
executable on GitHub's Ubuntu 22.04 runner and uploads it to a GitHub Release.

## Publish a binary

Create and publish a release in this repository. By default, its tag is also
used as the CuraEngine ref. For example, a builder release tagged `5.11.0`
builds the upstream CuraEngine tag `5.11.0`.

If the builder release tag differs from the upstream ref, create a repository
Actions variable named `CURAENGINE_REF` with the desired CuraEngine branch,
tag, or commit before publishing the release.

The workflow can also be run manually from **Actions → Build CuraEngine release
binary → Run workflow**. Supply:

- `curaengine_ref`: the upstream CuraEngine branch, tag, or commit.
- `release_tag`: an existing release in this repository that will receive the
  asset.

The release receives the executable and its SHA-256 checksum. The upload uses
`--clobber`, so rerunning the workflow safely replaces assets with the same
names.

## Build script

The workflow runs:

```bash
./scripts/build-curaengine.sh 5.11.0
```

The script expects Linux, Git, Conan 2, CMake 3.23 or newer, and Ninja. It
places output in `./dist`, or in the directory specified by `OUTPUT_DIR`.
It builds the command-line engine without the optional Arcus and plugin
components to avoid requiring their shared libraries alongside the binary.

The workflow pins Conan and CMake versions and uses GCC 12, which satisfies the
current CuraEngine recipe. Older CuraEngine releases that use Conan 1 may need
a separate legacy build workflow. Python build-tool versions are kept in
`requirements-build.txt`, which also provides a stable key for the GitHub
Actions pip cache.

The build script conditionally applies the compatibility patches in `patches/`.
For CuraEngine 5.13.0 these add the missing standard `<iomanip>` and `<cstddef>`
includes needed by its uses of `std::setprecision` and `size_t` when compiling
with GCC 12.
