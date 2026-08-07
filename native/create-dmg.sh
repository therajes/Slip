#!/bin/zsh
set -euo pipefail
[[ $# -eq 2 ]] || { print -u2 "Usage: $0 Slip.app Slip-version.dmg"; exit 2; }
APP_PATH="${1:A}"; OUTPUT_PATH="${2:A}"; SCRIPT_DIR="${0:A:h}"
[[ -d "$APP_PATH" && "${APP_PATH:t}" == "Slip.app" ]] || { print -u2 "Slip.app not found"; exit 1; }
mkdir -p "${OUTPUT_PATH:h}"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/slip-dmg.XXXXXX"); MOUNT_DIR="$WORK_DIR/mount"; STAGING_DIR="$WORK_DIR/staging"; WRITABLE_DMG="$WORK_DIR/Slip-writable.dmg"
mkdir -p "$MOUNT_DIR" "$STAGING_DIR/.background"
cleanup() { hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true; [[ "$WORK_DIR" == "${TMPDIR:-/tmp}"/slip-dmg.* ]] && /bin/rm -rf "$WORK_DIR"; }
trap cleanup EXIT
ditto "$APP_PATH" "$STAGING_DIR/Slip.app"; ln -s /Applications "$STAGING_DIR/Applications"
xcrun swift "$SCRIPT_DIR/DMGBackground.swift" "$STAGING_DIR/.background/background.png"
hdiutil create -volname Slip -srcfolder "$STAGING_DIR" -ov -format UDRW -fs HFS+ "$WRITABLE_DMG" >/dev/null
hdiutil attach "$WRITABLE_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noverify >/dev/null
osascript -e 'on run argv' -e 'set p to item 1 of argv' -e 'set f to POSIX file p as alias' -e 'set bg to POSIX file (p & "/.background/background.png") as alias' -e 'tell application "Finder"' -e 'open f' -e 'delay 1' -e 'set w to container window of f' -e 'set current view of w to icon view' -e 'set toolbar visible of w to false' -e 'set statusbar visible of w to false' -e 'set bounds of w to {140, 120, 900, 600}' -e 'set v to icon view options of w' -e 'set arrangement of v to not arranged' -e 'set icon size of v to 112' -e 'set text size of v to 14' -e 'set background picture of v to bg' -e 'set position of item "Slip.app" of f to {190, 240}' -e 'set position of item "Applications" of f to {570, 240}' -e 'close w' -e 'open f' -e 'delay 2' -e 'end tell' -e 'end run' "$MOUNT_DIR"
sync; hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_PATH" -ov >/dev/null
hdiutil verify "$OUTPUT_PATH" >/dev/null
print "DMG ready: $OUTPUT_PATH"
