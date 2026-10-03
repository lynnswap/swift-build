#!/usr/bin/env bash
set -euo pipefail

# Run on an otherwise clean Homebrew installation; never replace a user's keg.
release_dir="${1:?Usage: scripts/test-homebrew.sh <release-dir> }"
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
# Test the transferred candidate bytes against the canonical Formula checksum,
# rather than downloading a separate copy during verification.
cache="$(brew --cache --build-from-source "$formula")"
mkdir -p "$(dirname "$cache")"
source_archive="$(awk '$2 ~ /^custom-xcode-build-service-.*\.tar\.gz$/ { print $2 }' "$release_dir/SHA256SUMS.txt")"
expected_version="${source_archive#custom-xcode-build-service-}"
expected_version="${expected_version%.tar.gz}"
brew info --json=v2 "$formula" | python3 -c '
import json, sys
version = json.load(sys.stdin)["formulae"][0]["versions"]["stable"]
if version != sys.argv[1]:
    sys.exit(f"Homebrew parsed version {version!r}; expected {sys.argv[1]!r}.")
' "$expected_version"
cp "$release_dir/$source_archive" "$cache"
brew install --build-bottle "$formula"
cd "$work"
# Keep a candidate bottle for diagnosis if a subsequent installed test fails.
brew bottle --json --root-url=https://example.invalid/custom-xcode-build-service-verification "$formula"
brew bottle --merge --write --no-commit "$work"/*.bottle.json
bottle_cache="$(brew --cache --force-bottle "$formula")"
cp "$work"/*.bottle.tar.gz "$bottle_cache"
verify_installed_payload() {
  local prefix
  prefix="$(brew --prefix "$formula")"
  # Run Xcode's package tests outside Homebrew's sandbox; its manifest loader
  # creates its own sandbox. The regular Formula test covers C and SwiftPM here.
  python3 "$prefix/share/custom-xcode-build-service/verify.py" verify-payload \
    --payload "$prefix/libexec" \
    --fixture-dir "$prefix/share/custom-xcode-build-service/CommandLineTool"
}
brew test "$formula"
verify_installed_payload
brew uninstall "$formula"
brew install --force-bottle "$formula"
brew info --json=v2 "$formula" | python3 -c '
import json, sys
installed = json.load(sys.stdin)["formulae"][0]["installed"][0]
if not installed["poured_from_bottle"]:
    sys.exit("Homebrew verification expected a bottle installation.")
'
brew test "$formula"
verify_installed_payload
