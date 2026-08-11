# Slip 1.1.2 — Correct artwork everywhere

Slip 1.1.2 fixes artwork handling across IPA imports, Apple Account profiles, and the iPhone Apps inventory.

## What changed

- IPA previews now honor the icon names declared in the app’s Info.plist. This supports ordinary AppIcon assets, legacy CgBI artwork, and unusually named assets such as YouTubePlus’s `logo_youtube…` icon.
- Every installed iPhone app now displays the same icon supplied by iOS SpringBoard.
- SpringBoard icon retrieval uses one device connection and degrades gracefully to a distinct initials avatar if iOS does not return an icon.
- Each installed-app row has exactly one selection checkbox. Slip-managed status is shown as a compact refresh badge on the app artwork rather than a second square control.
- Apple Account profile photos are center-cropped and stored as efficient 512×512 PNGs.
- Profile-photo rendering is constrained at both the image and avatar levels, preventing large uploads from taking over the screen.

## Verified

- Extracted the correct preview from both Home Workout and YouTubePlus IPAs in Downloads.
- Loaded 37 user apps from a connected iPhone on iOS 27.0 and retrieved icons for all 37.
- Passed the native Swift build and Rust core test suite.

The downloadable build is development-signed and not notarized.
