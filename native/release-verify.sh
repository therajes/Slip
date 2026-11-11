#!/bin/zsh
set -euo pipefail
[[ $# == 1 ]] || { print -u2 'Usage: release-verify.sh Slip.app'; exit 2; }
app=${1:A}
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
[[ "$version" == "$build" ]] || { print -u2 'App build version mismatch'; exit 1; }
core_version=$("$app/Contents/Resources/sideloom-core" version | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
[[ "$core_version" == "$version" && $("$app/Contents/Resources/slip-anisette" --version) == "$version" ]] || { print -u2 'Bundled helper version mismatch'; exit 1; }
expected_team=""
for relative in Contents/MacOS/Slip Contents/Resources/sideloom-core Contents/Resources/slip-anisette; do
    case "$relative" in
      Contents/MacOS/Slip) identifier=app.sideloom.native ;;
      Contents/Resources/sideloom-core) identifier=app.sideloom.native.core ;;
      *) identifier=app.sideloom.native.anisette ;;
    esac
    binary="$app/$relative"
    codesign --verify --strict "$binary"
    metadata=$(codesign -dv --verbose=4 "$binary" 2>&1)
    print -r -- "$metadata" | /usr/bin/grep -Fxq "Identifier=$identifier"
    current_team=$(print -r -- "$metadata" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    if [[ "$relative" == Contents/MacOS/Slip ]]; then expected_team="$current_team"; fi
    [[ "$current_team" == "$expected_team" ]] || { print -u2 'App/helper signing team mismatch'; exit 1; }
    [[ $(lipo -archs "$binary") == arm64 ]] || { print -u2 'Unexpected binary architecture'; exit 1; }
    if [[ "${SLIP_PRODUCTION_SIGNING:-0}" == 1 ]]; then
        print -r -- "$metadata" | /usr/bin/grep -q 'flags=.*runtime'
        print -r -- "$metadata" | /usr/bin/grep -q '^Timestamp='
        print -r -- "$metadata" | /usr/bin/grep -q '^Authority=Developer ID Application:'
        [[ -n "${SLIP_DEVELOPER_TEAM_ID:-}" ]] || { print -u2 'Set SLIP_DEVELOPER_TEAM_ID for production verification'; exit 1; }
        print -r -- "$metadata" | /usr/bin/grep -Fxq "TeamIdentifier=$SLIP_DEVELOPER_TEAM_ID"
    fi
done
codesign --verify --deep --strict "$app"
print "Verified Slip $version app/core/helper versions, architectures and signatures"
