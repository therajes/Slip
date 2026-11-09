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

SWIFT_BIN=${SWIFT_BIN:-$(xcrun --find swift 2>/dev/null || command -v swift || true)}
if [[ -z "$SWIFT_BIN" ]]; then
    print -u2 "Swift is required. Install Xcode command line tools and try again."
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

# SwiftPM's Xcode build path can otherwise stamp the deployment target as
# the SDK version. Record the actual SDK independently of the macOS 26 minimum.
NATIVE_SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
"$SWIFT_BIN" build --package-path "$NATIVE_DIR" -c release --arch arm64 \
    -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$NATIVE_SDK_VERSION"
SWIFT_BIN_DIR=$("$SWIFT_BIN" build --package-path "$NATIVE_DIR" -c release --arch arm64 --show-bin-path)

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
ditto "$SWIFT_BIN_DIR/SlipNative" "$APP_DIR/Contents/MacOS/Slip"
ditto "$CORE_DIR/target/release/sideloom-core" "$APP_DIR/Contents/Resources/sideloom-core"
ditto "$NATIVE_DIR/Assets.xcassets/SlipAppIcon.imageset/SlipAppIcon-Light.png" "$APP_DIR/Contents/Resources/SlipAppIcon-Light.png"
ditto "$NATIVE_DIR/Assets.xcassets/SlipAppIcon.imageset/SlipAppIcon-Dark.png" "$APP_DIR/Contents/Resources/SlipAppIcon-Dark.png"
ditto "$NATIVE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
ditto "$NATIVE_DIR/Resources/Credits.rtf" "$APP_DIR/Contents/Resources/Credits.rtf"
ditto "$NATIVE_DIR/LICENSE" "$APP_DIR/Contents/Resources/License.txt"
ditto "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/OriginalLicense.txt"
ditto "$NATIVE_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/ThirdPartyNotices.txt"
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=26.0 -framework Foundation \
    "$NATIVE_DIR/AnisetteHelper.m" -o "$APP_DIR/Contents/Resources/slip-anisette"
chmod 755 "$APP_DIR/Contents/MacOS/Slip" "$APP_DIR/Contents/Resources/sideloom-core" "$APP_DIR/Contents/Resources/slip-anisette"

xcrun actool "$NATIVE_DIR/Assets.xcassets" "$NATIVE_DIR/SlipIcon.icon" \
    --app-icon SlipIcon \
    --output-partial-info-plist "$OUTPUT_DIR/icon-info.plist" \
    --compile "$APP_DIR/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --target-device mac \
    --warnings \
    --notices >/dev/null

codesign --force --sign "$SIDELOOM_SIGN_IDENTITY" --identifier app.sideloom.native.anisette "$APP_DIR/Contents/Resources/slip-anisette"
codesign --force --sign "$SIDELOOM_SIGN_IDENTITY" --identifier app.sideloom.native.core "$APP_DIR/Contents/Resources/sideloom-core"
codesign --force --deep --sign "$SIDELOOM_SIGN_IDENTITY" --identifier app.sideloom.native "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "${SLIP_PRODUCTION_SIGNING:-0}" == 1 ]]; then
    "$NATIVE_DIR/production-sign.sh" app "$APP_DIR"
fi

echo "$APP_DIR"
