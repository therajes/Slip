#!/bin/zsh
set -euo pipefail
# Identity and notary keychain profile must be provisioned securely by the operator.
[[ $# == 2 ]] || { print -u2 'Usage: production-sign.sh app|dmg path'; exit 2; }
: ${SLIP_DEVELOPER_ID:?Set a Developer ID Application signing identity}
: ${SLIP_DEVELOPER_TEAM_ID:?Set the expected Developer ID team identifier}
: ${SLIP_NOTARY_PROFILE:?Set a notarytool keychain profile}
[[ "$SLIP_DEVELOPER_ID" == 'Developer ID Application:'* ]] || { print -u2 'Developer ID Application identity required'; exit 1; }
artifact=${2:A}
if [[ "$1" == app ]]; then
  for helper in slip-anisette sideloom-core; do
    codesign --force --options runtime --timestamp --sign "$SLIP_DEVELOPER_ID" "$artifact/Contents/Resources/$helper"
  done
  codesign --force --options runtime --timestamp --sign "$SLIP_DEVELOPER_ID" "$artifact"
  codesign --verify --deep --strict "$artifact"
  "${0:A:h}/release-verify.sh" "$artifact"
  staging=$(mktemp -d)
  trap 'rm -rf "$staging"' EXIT
  ditto -c -k --keepParent "$artifact" "$staging/Slip.zip"
  xcrun notarytool submit "$staging/Slip.zip" --keychain-profile "$SLIP_NOTARY_PROFILE" --wait
elif [[ "$1" == dmg ]]; then
  codesign --force --timestamp --sign "$SLIP_DEVELOPER_ID" "$artifact"
  xcrun notarytool submit "$artifact" --keychain-profile "$SLIP_NOTARY_PROFILE" --wait
else
  exit 2
fi
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
if [[ "$1" == app ]]; then spctl --assess --type execute "$artifact"; else spctl --assess --type open --context context:primary-signature "$artifact"; fi
