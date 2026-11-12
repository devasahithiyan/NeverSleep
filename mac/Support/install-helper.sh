#!/bin/bash
# Installs (or removes) NeverSleep's privileged helper as a standard launch daemon.
# Must run as root. NeverSleep runs it through the macOS administrator prompt:
#   install-helper.sh install   /Applications/NeverSleep.app
#   install-helper.sh uninstall
#
# - Copies the helper to /Library/PrivilegedHelperTools (root-owned).
# - Pins the NeverSleep.app code-signing requirement in a root-owned file; the helper only
#   accepts XPC clients that satisfy it.
# - Loads /Library/LaunchDaemons/com.neversleep.helper.plist with launchctl.
set -euo pipefail

LABEL="com.neversleep.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
CONF_DIR="/Library/Application Support/NeverSleep"
REQ_FILE="$CONF_DIR/client-requirement"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 77; fi

unload() { launchctl bootout "system/$LABEL" 2>/dev/null || true; }

case "${1:-}" in
  uninstall)
    unload
    /usr/bin/pmset -a disablesleep 0 || true
    rm -f "$PLIST" "$DEST" "$REQ_FILE" "$CONF_DIR/disablesleep.on"
    echo "uninstalled"
    ;;
  install)
    APP="${2:-}"
    [[ "$APP" == *.app && -x "$APP/Contents/MacOS/NeverSleepHelper" ]] || { echo "bad app path" >&2; exit 64; }
    /usr/bin/codesign --verify --strict "$APP"
    REQ="$(/usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n 's/^# designated => //p')"
    [[ -n "$REQ" ]] || { echo "could not read the app's code requirement" >&2; exit 65; }

    unload
    mkdir -p /Library/PrivilegedHelperTools "$CONF_DIR"
    install -m 755 -o root -g wheel "$APP/Contents/MacOS/NeverSleepHelper" "$DEST"
    printf '%s\n' "$REQ" > "$REQ_FILE"
    chown root:wheel "$REQ_FILE"; chmod 644 "$REQ_FILE"

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$DEST</string>
  <key>MachServices</key>
  <dict><key>$LABEL</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>com.neversleep.app</string></array>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"; chmod 644 "$PLIST"
    launchctl enable "system/$LABEL" 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
    echo "installed"
    ;;
  *)
    echo "usage: $0 install <NeverSleep.app> | uninstall" >&2; exit 64 ;;
esac
