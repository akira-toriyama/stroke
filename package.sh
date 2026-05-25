#!/bin/zsh
# Build a release binary and assemble the .app bundle.
#
# Modes:
#   ./package.sh           release → Wand.app     / com.wand.wand
#   ./package.sh --dev     dev     → Wand-dev.app / com.wand.wand.dev
#
# Why two flavors: the dev build (run from the repo) and a co-installed
# Homebrew release would otherwise share the same bundle id, so macOS
# would treat them as one app for TCC and the System Settings list
# would show two indistinguishable "wand" entries. The dev variant
# gets its own bundle id + display name "wand (dev)" so each side
# keeps its own Accessibility grant.
#
# The RELEASE bundle id is com.wand.wand — keep it stable across
# versions: macOS keys the Accessibility (TCC) grant + the self-signed
# cert to it.
#
# TCC: ad-hoc signing is not a stable identity → re-grant on every
# rebuild. Persist with a self-signed cert via
# ./setup-signing-cert.sh (writes .signing-id).
set -e
cd "$(dirname "$0")"

MODE="release"
PLIST="Info.plist"
APP="Wand.app"
if [[ "${1:-}" == "--dev" ]]; then
  MODE="dev"; PLIST="Info.plist.dev"; APP="Wand-dev.app"
fi

swift build -c release

# Clean up any prior bundle of either flavor before re-assembling.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
cp .build/release/wand "$APP/Contents/MacOS/wand"   # = CFBundleExecutable
# CFBundleIconFile = Wand (set in Info.plist) tells Launch Services
# to look for Wand.icns in Resources/. Committed binary lives in
# assets/; regenerate with scripts/make-icon.sh.
if [[ -f assets/Wand.icns ]]; then
  cp assets/Wand.icns "$APP/Contents/Resources/Wand.icns"
fi

# Identity precedence: $CODESIGN_ID > .signing-id file > ad-hoc ("-").
ID="${CODESIGN_ID:-}"
if [[ -z "$ID" && -f .signing-id ]]; then ID="$(cat .signing-id)"; fi
ID="${ID:--}"
codesign --force --sign "$ID" "$APP"

echo "built $APP  ($MODE, signed: $ID)"
echo "launch: open $APP   |   quit: pkill -f /Contents/MacOS/wand"
