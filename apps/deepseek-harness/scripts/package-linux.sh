#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  printf '%s\n' 'usage: package-linux.sh <package-source> <runtime.tgz> <fnpack> <output-dir>' >&2
  exit 64
fi

package_source=$1
runtime_archive=$2
fnpack=$3
output_dir=$4

# The staging tree copies the whole runtime, so it needs more room than a
# small tmpfs offers. TMPDIR lets the build host place it on a larger
# filesystem; the default stays the system temporary directory.
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-package.XXXXXXXX")
cleanup() {
  rm -rf -- "$stage_root"
}
trap cleanup EXIT HUP INT TERM

package_stage=${stage_root}/package
mkdir -p "$package_stage"
cp -R -- "$package_source/." "$package_stage/"

mkdir -p "$output_dir"
existing_artifacts=$(find "$output_dir" -maxdepth 1 -type f -name '*.fpk' -print)
if [ -n "$existing_artifacts" ]; then
  printf 'Refusing to package into a directory containing existing FPK files: %s\n' "$output_dir" >&2
  exit 1
fi

# DrvFS does not expose useful source modes. Normalize package-owned files,
# then restore the runtime directly from its Linux tarball.
rm -rf -- "$package_stage/app/server"
find "$package_stage" -type d -exec chmod 0755 {} +
find "$package_stage" -type f -exec chmod 0644 {} +
find "$package_stage/cmd" -type f -exec chmod 0755 {} +

mkdir -p "$package_stage/app/server"
tar -xzf "$runtime_archive" -C "$package_stage/app/server"

cd "$output_dir"
"$fnpack" build --directory "$package_stage"

set -- "$output_dir"/*.fpk
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  printf 'fnpack must produce exactly one FPK in %s\n' "$output_dir" >&2
  exit 1
fi
