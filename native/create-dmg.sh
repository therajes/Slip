#!/bin/zsh
set -euo pipefail

[[ $# -eq 2 ]] || { print -u2 "Usage: $0 Slip.app Slip-version.dmg"; exit 2; }
APP_PATH="${1:A}"
OUTPUT_PATH="${2:A}"
SCRIPT_DIR="${0:A:h}"
[[ -d "$APP_PATH" && "${APP_PATH:t}" == "Slip.app" ]] || { print -u2 "Slip.app not found"; exit 1; }
mkdir -p "${OUTPUT_PATH:h}"

PACKAGING_PYTHON="$SCRIPT_DIR/build/dmg-tools/bin/python"
if [[ ! -x "$PACKAGING_PYTHON" ]]; then
    python3 -m venv "$SCRIPT_DIR/build/dmg-tools"
fi
"$PACKAGING_PYTHON" -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r "$SCRIPT_DIR/requirements-dmg.txt"

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
WORK_DIR=$(mktemp -d "$TEMP_ROOT/slip-dmg.XXXXXX")
MOUNT_DIR="$WORK_DIR/mount"
STAGING_DIR="$WORK_DIR/staging"
WRITABLE_DMG="$WORK_DIR/Slip-writable.dmg"
mkdir -p "$MOUNT_DIR" "$STAGING_DIR/.background"
cleanup() {
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    if [[ "$WORK_DIR" == "$TEMP_ROOT"/slip-dmg.* ]]; then
        /bin/rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGING_DIR/Slip.app"
ln -s /Applications "$STAGING_DIR/Applications"
xcrun swift "$SCRIPT_DIR/DMGBackground.swift" "$STAGING_DIR/.background/background.png"
hdiutil create -volname Slip -srcfolder "$STAGING_DIR" -ov -format UDRW -fs HFS+ "$WRITABLE_DMG" >/dev/null
hdiutil attach "$WRITABLE_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen -noverify >/dev/null
# Write Finder metadata directly so packaging never needs a GUI or Automation permission.
"$PACKAGING_PYTHON" "$SCRIPT_DIR/dmg-layout.py" "$MOUNT_DIR"
sync
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_PATH" -ov >/dev/null
hdiutil verify "$OUTPUT_PATH" >/dev/null
hdiutil attach "$OUTPUT_PATH" -mountpoint "$MOUNT_DIR" -readonly -nobrowse -noautoopen -noverify >/dev/null
"$PACKAGING_PYTHON" "$SCRIPT_DIR/dmg-layout.py" "$MOUNT_DIR" --verify
codesign --verify --deep --strict "$MOUNT_DIR/Slip.app"
hdiutil detach "$MOUNT_DIR" -quiet
if [[ "${SLIP_PRODUCTION_SIGNING:-0}" == 1 ]]; then
    "$SCRIPT_DIR/production-sign.sh" dmg "$OUTPUT_PATH"
fi
print "DMG ready: $OUTPUT_PATH"
