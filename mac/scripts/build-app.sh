#!/bin/bash
# Builds NeverSleep.app (app + privileged helper + launchd plist) and code-signs it.
#
#   scripts/build-app.sh              # build + ad-hoc sign
#   scripts/build-app.sh --install    # also replace /Applications/NeverSleep.app and launch it
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#
# The bundle is assembled OUTSIDE the project folder (default ~/Library/Caches/NeverSleep),
# because folders synced by iCloud Drive (like ~/Desktop) get file-provider attributes and
# partial syncs that break strict code-signature checks.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/NeverSleep}"
OUT="$BUILD_DIR/NeverSleep.app"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

swift build -c "$CONFIG" --product NeverSleep
swift build -c "$CONFIG" --product NeverSleepHelper
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

mkdir -p "$BUILD_DIR"
STAGE="$(mktemp -d "$BUILD_DIR/stage.XXXXXX")"
APP="$STAGE/NeverSleep.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/install-helper.sh "$APP/Contents/Resources/install-helper.sh"
chmod 755 "$APP/Contents/Resources/install-helper.sh"
cp "$BIN/NeverSleep" "$APP/Contents/MacOS/NeverSleep"
cp "$BIN/NeverSleepHelper" "$APP/Contents/MacOS/NeverSleepHelper"
xattr -cr "$APP"

# Sign inside-out: helper first (with its own identifier), then the app bundle.
codesign --force --options runtime --timestamp=none --identifier com.neversleep.helper \
  --sign "$IDENTITY" "$APP/Contents/MacOS/NeverSleepHelper"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Swap the finished bundle into place.
if [[ -e "$OUT" ]]; then mv "$OUT" "$STAGE/previous.app"; fi
mv "$APP" "$OUT"
echo
echo "Built $OUT (signed with: $IDENTITY)"

if [[ $INSTALL -eq 1 ]]; then
  osascript -e 'tell application id "com.neversleep.app" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -qf "NeverSleep.app/Contents/MacOS/NeverSleep$" || break; sleep 0.5; done
  if [[ -e /Applications/NeverSleep.app ]]; then
    # Never copy over an existing bundle (stale signature files get merged in); move it to the Trash.
    mv /Applications/NeverSleep.app "$HOME/.Trash/NeverSleep-$(date +%Y%m%d-%H%M%S).app"
  fi
  ditto --norsrc --noextattr "$OUT" /Applications/NeverSleep.app
  codesign --verify --strict /Applications/NeverSleep.app
  echo "Installed /Applications/NeverSleep.app"
  # The helper only accepts the exact build it was installed for, so update it too.
  # macOS shows its own administrator password prompt for this.
  /Applications/NeverSleep.app/Contents/MacOS/NeverSleep --install-helper || echo "Helper not updated: open NeverSleep › Settings › Helper › Install"
  open /Applications/NeverSleep.app
  echo "Launched /Applications/NeverSleep.app"
else
  echo "Install with: scripts/build-app.sh --install"
fi
