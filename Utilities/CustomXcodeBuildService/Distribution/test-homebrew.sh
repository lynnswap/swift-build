#!/usr/bin/env bash
set -euo pipefail

# Run on an otherwise clean Homebrew installation; never replace a user's keg.
release_dir="${1:?Usage: test-homebrew.sh <release-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_dir="$(cd "$release_dir" && pwd)"
formula=custom-xcode-build-service/verification/custom-xcode-build-service
if brew list --formula --versions custom-xcode-build-service >/dev/null 2>&1; then
  echo "Uninstall the existing Homebrew custom-xcode-build-service before running this test." >&2
  exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
brew tap-new --no-git custom-xcode-build-service/verification
cleanup() {
  local result=$?
  trap - EXIT
  if brew list --formula --versions custom-xcode-build-service >/dev/null 2>&1; then
    brew uninstall --force "$formula" || result=1
  fi
  brew untap custom-xcode-build-service/verification || result=1
  brew untrust --formula "$formula" || result=1
  if [[ "$result" == 0 ]]; then
    rm -rf "$work"
  else
    echo "Verification artifacts retained at: $work" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
cp "$release_dir/custom-xcode-build-service.rb" "$(brew --repository custom-xcode-build-service/verification)/Formula/custom-xcode-build-service.rb"
brew trust --formula "$formula"
brew style "$formula"
brew audit --except=installed "$formula"
# Seed Homebrew with the exact candidate archive; its Formula verifies the checksum.
cache="$(brew --cache --build-from-source "$formula")"
mkdir -p "$(dirname "$cache")"
archive=custom-xcode-build-service-darwin-arm64.tar.gz
expected_version="$(/usr/bin/tar -xOf "$release_dir/$archive" manifest.json | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
cp "$release_dir/$archive" "$cache"
brew install "$formula"
brew test "$formula"
prefix="$(brew --prefix "$formula")"
test "$("$prefix/bin/custom-xcode-build-service" --version)" = "$expected_version"
python3 "$script_dir/release.py" verify-payload --payload "$prefix/libexec"
