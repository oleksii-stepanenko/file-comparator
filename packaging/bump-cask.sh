#!/usr/bin/env bash
# Point the Homebrew cask at a published release (use when CI has no TAP_GITHUB_TOKEN).
#   packaging/bump-cask.sh 1.0.1
# Downloads the release DMG, computes its sha256, rewrites Casks/file-comparator.rb in a
# fresh clone of oleksii-stepanenko/homebrew-tap, commits and pushes.
set -euo pipefail

VERSION="${1:?usage: bump-cask.sh <version, e.g. 1.0.1>}"
REPO="oleksii-stepanenko/file-comparator"
TAP="oleksii-stepanenko/homebrew-tap"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/FileComparator.dmg"
HERE="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching ${URL}"
curl -fsSL -o "$TMP/FileComparator.dmg" "$URL"
SHA="$(shasum -a 256 "$TMP/FileComparator.dmg" | awk '{print $1}')"
echo "sha256 = ${SHA}"

git clone -q --depth 1 "https://github.com/${TAP}.git" "$TMP/tap"
CASK="$TMP/tap/Casks/file-comparator.rb"
[ -f "$CASK" ] || cp "$HERE/homebrew/file-comparator.rb" "$CASK"
sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$CASK"

cd "$TMP/tap"
git add Casks/file-comparator.rb
if git diff --cached --quiet; then echo "Cask already at ${VERSION}."; exit 0; fi
git commit -qm "file-comparator ${VERSION}"
git push -q
echo "Cask bumped to ${VERSION}."
