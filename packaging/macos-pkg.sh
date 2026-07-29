#!/bin/sh
# Turn a release build of Mesh.app into an installable .pkg.
#
#   packaging/macos-pkg.sh app/build/macos/Build/Products/Release/Mesh.app dist/Mesh.pkg
#
# A component package and nothing more: it drops the bundle into /Applications and stops there.
# The daemon is installed separately by install.sh, and an app package that also tried to place
# a root-owned launchd job would need an installer script running as root for something the user
# may already have.
#
# Unsigned, deliberately. Signing needs a Developer ID certificate this repository does not
# carry, and notarization needs an Apple account; CI can produce neither. Gatekeeper therefore
# refuses it on a double click, and whoever installs it opens it from the Finder's context menu
# instead. That is fine for a build artifact a reviewer is trying out and is not fine for
# anything shipped, which is signed and notarized outside this script.
set -eu

APP="${1:-}"
OUT="${2:-}"

die() { echo "error: $*" >&2; exit 1; }

if [ -z "$APP" ] || [ -z "$OUT" ]; then
    echo "usage: macos-pkg.sh <path to Mesh.app> <output .pkg>" >&2
    exit 2
fi

command -v pkgbuild >/dev/null 2>&1 || die "pkgbuild is macOS only; this cannot run here"
[ -d "$APP" ] || die "no app bundle at $APP; run 'flutter build macos --release' first"
# A directory named .app is not yet a bundle. Catching it here rather than letting pkgbuild
# build a package around an empty tree, which it will do without complaint.
[ -f "$APP/Contents/Info.plist" ] || die "$APP has no Contents/Info.plist, so it is not a bundle"

# The version belongs to the app, so it comes from the app's manifest rather than from a number
# repeated in the workflow. Everything after `+` is Flutter's build number, which installer
# version comparison has no meaning for.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pubspec="$here/../app/pubspec.yaml"
[ -f "$pubspec" ] || die "cannot find $pubspec to read the version from"
VERSION=$(sed -n 's/^version:[[:space:]]*\([^[:space:]+]*\).*/\1/p' "$pubspec" | head -1)
[ -n "$VERSION" ] || die "no version: line in $pubspec"

outdir=$(dirname -- "$OUT")
mkdir -p "$outdir"

pkgbuild \
    --component "$APP" \
    --identifier dev.mesh.app \
    --version "$VERSION" \
    --install-location /Applications \
    "$OUT"

echo "$OUT  $VERSION  $(wc -c < "$OUT" | tr -d ' ') bytes"
