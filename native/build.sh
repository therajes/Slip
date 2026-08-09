#!/bin/zsh
set -euo pipefail

NATIVE_DIR=${0:A:h}
PROJECT_DIR=${NATIVE_DIR:h}
CORE_DIR="$PROJECT_DIR/src-tauri"
OUTPUT_DIR="$NATIVE_DIR/build"
APP_DIR="$OUTPUT_DIR/Slip.app"
CARGO_BIN=${CARGO_BIN:-$(command -v cargo || true)}
if [[ -z "$CARGO_BIN" && -x "$HOME/.cargo/bin/cargo" ]]; then
    CARGO_BIN="$HOME/.cargo/bin/cargo"
fi
if [[ -z "$CARGO_BIN" ]]; then
    print -u2 "Rust is required. Install it from https://rustup.rs and try again."
    exit 1
fi

SIDELOOM_SIGN_IDENTITY=${SIDELOOM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F\" '/Apple Development/ { print $2; exit }')}
if [[ -z "$SIDELOOM_SIGN_IDENTITY" ]] || ! security find-identity -v -p codesigning | grep -Fq "$SIDELOOM_SIGN_IDENTITY"; then
    SIDELOOM_SIGN_IDENTITY="-"
fi

"$CARGO_BIN" build \
    --manifest-path "$CORE_DIR/Cargo.toml" \
    --no-default-features \
    --release \
    --bin sideloom-core

swift build --package-path "$NATIVE_DIR" -c release --arch arm64
SWIFT_BIN_DIR=$(swift build --package-path "$NATIVE_DIR" -c release --arch arm64 --show-bin-path)

if [[ -d "$APP_DIR" ]]; then
    mv "$APP_DIR" "$OUTPUT_DIR/Slip.previous-$(date +%s).app"
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto "$SWIFT_BIN_DIR/SlipNative" "$APP_DIR/Contents/MacOS/Slip"
ditto "$CORE_DIR/target/release/sideloom-core" "$APP_DIR/Contents/Resources/sideloom-core"
ditto "$PROJECT_DIR/src-tauri/icons/icon.icns" "$APP_DIR/Contents/Resources/Slip.icns"
ditto "$NATIVE_DIR/Assets.xcassets/SlipAppIcon.imageset/SlipAppIcon-Light.png" "$APP_DIR/Contents/Resources/SlipAppIcon-Light.png"
ditto "$NATIVE_DIR/Assets.xcassets/SlipAppIcon.imageset/SlipAppIcon-Dark.png" "$APP_DIR/Contents/Resources/SlipAppIcon-Dark.png"
ditto "$NATIVE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/Slip" "$APP_DIR/Contents/Resources/sideloom-core"

xcrun actool "$NATIVE_DIR/Assets.xcassets" \
    --compile "$APP_DIR/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --target-device mac \
    --warnings \
    --notices >/dev/null

codesign --force --sign "$SIDELOOM_SIGN_IDENTITY" --identifier app.sideloom.native.core "$APP_DIR/Contents/Resources/sideloom-core"
codesign --force --deep --sign "$SIDELOOM_SIGN_IDENTITY" --identifier app.sideloom.native "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
