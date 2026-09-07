#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Utilities/build-custom-xcode-build-service.sh --version custom-vX.Y.Z --output-dir DIR [--revision COMMIT] [--jobs N]

Builds committed source with Xcode 27 on Apple Silicon. DIR must be absent or
empty. Keeps the isolated source, build directories, and distributable payload
under DIR; never installs the service or changes the original Package.resolved.
EOF
}

version=""
output_dir=""
revision="HEAD"
jobs=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--output-dir|--revision|--jobs)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 1; }
      case "$1" in
        --version) version="$2" ;;
        --output-dir) output_dir="$2" ;;
        --revision) revision="$2" ;;
        --jobs) jobs="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
[[ -n "$version" && -n "$output_dir" ]] || { usage >&2; exit 1; }
[[ "$version" =~ ^custom-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || {
  echo "Version must look like custom-v1.2.3 or custom-v1.2.3-beta.1" >&2; exit 1;
}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be positive" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "Building this distribution requires an Apple Silicon Mac." >&2; exit 1;
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_revision="$(git -C "$repo_root" rev-parse --verify --end-of-options "$revision^{commit}")"
# Keep every build, test, and metadata query on the initially selected toolchain.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select --print-path)}"
xcode_info="$(xcrun xcodebuild -version)"
[[ "$xcode_info" == Xcode\ 27.* ]] || { echo "Select Xcode 27 before building." >&2; exit 1; }
[[ ! -e "$output_dir" || -d "$output_dir" ]] || { echo "Not a directory: $output_dir" >&2; exit 1; }
[[ ! -L "$output_dir" ]] || { echo "Output directory must not be a symlink: $output_dir" >&2; exit 1; }
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
[[ -z "$(ls -A "$output_dir")" ]] || { echo "Output directory must be empty: $output_dir" >&2; exit 1; }
mkdir "$output_dir/source" "$output_dir/build"
git -C "$repo_root" archive "$source_revision" | tar -x -C "$output_dir/source"
source_dir="$output_dir/source"
cp "$source_dir/.github/custom-build-service/ServiceDependencies.resolved" "$source_dir/Package.resolved"
printf '%s\n' "$source_revision" > "$output_dir/source-revision.txt"

# These options change the dependency graph or service independently of the pins.
unset SWIFTCI_USE_LOCAL_DEPS SWIFTBUILD_LLBUILD_FWK SWIFTBUILD_STATIC_LINK
unset XCBBUILDSERVICE_PATH SWBBUILDSERVICE_PATH
common=(--configuration release --arch arm64 --jobs "$jobs" --build-system swiftbuild
  --cache-path "$output_dir/build/cache" --config-path "$output_dir/build/config"
  --security-path "$output_dir/build/security")
service_args=("${common[@]}" --package-path "$source_dir"
  --scratch-path "$output_dir/build/service" --force-resolved-versions)
cli_args=("${common[@]}" --package-path "$source_dir/Utilities/CustomXcodeBuildService"
  --scratch-path "$output_dir/build/cli")

printf '%s\n' "$xcode_info"
xcrun swift --version
xcrun swift build "${service_args[@]}" --product SWBBuildServiceBundle
cmp "$source_dir/Package.resolved" "$source_dir/.github/custom-build-service/ServiceDependencies.resolved"
xcrun swift test "${cli_args[@]}" --disable-xctest
xcrun swift build "${cli_args[@]}" --product custom-xcode-build-service
service_bin="$(xcrun swift build "${service_args[@]}" --show-bin-path)"
cli_bin="$(xcrun swift build "${cli_args[@]}" --show-bin-path)"
python3 "$source_dir/.github/custom-build-service/release.py" stage \
  --build-dir "$output_dir" --service-bin "$service_bin" --cli-bin "$cli_bin" --version "$version"
echo "Built payload: $output_dir/payload"
