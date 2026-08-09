# Changelog

## 1.1.0 — 2026-08-09

### Added

- Rebuilt the installer workspace around native macOS Liquid Glass containers, controls, navigation, and a persistent installation dock.
- Added adaptive Light Glass, Dark Glass, and Automatic Glass app-icon appearances compiled into Apple’s asset catalog, with an `.icns` compatibility fallback.
- Added Appearance settings for interface style, icon style, and enhanced motion; the macOS Reduce Motion preference remains authoritative.
- Added a live preflight system for IPA encryption, bundle IDs, minimum iOS compatibility, custom icon availability, typed plist values, duplicate keys, and protected identity keys.
- Added clearer App ID accounting, Wi-Fi/USB speed guidance, customization counts, inspection timing, and installation timing.
- Added real embedded IPA icon previews for local files and URL downloads, including Apple CgBI-optimized icon support.
- Added hardware-aware connected-iPhone previews with exact model resolution, Dynamic Island/notch details, and display-size proportions.

### Changed

- Unchanged IPA entries now use raw ZIP transfer instead of decompression and recompression. A 196 MB Home Workout IPA customization benchmark improved from 4.42 seconds to 1.15 seconds on the same Mac.
- Manual installation now prefers USB when both USB and trusted-network endpoints are available; background refresh can continue to prefer Wi-Fi.
- Core failures are converted to concise user-facing messages instead of exposing Rust source paths.
- Identity, extensions, and advanced metadata are separated into focused customization panes.
- Scroll indicators are hidden throughout the glass interface while trackpad, mouse, and keyboard scrolling remain available.

### Fixed

- Prevented identity-critical Info.plist keys from conflicting with the dedicated bundle identity controls.
- Prevented signing attempts for known encrypted executables and iPhones below the effective minimum iOS version.
- Preserved original compression data and permissions for untouched IPA entries.
- Prevented Automatic Glass from double-darkening the Dock icon under macOS Dark icon appearances.

## 1.0.0 — 2026-08-07

- First public native Slip release with IPA customization, Apple Account signing, direct USB/Wi-Fi installation, Keychain credentials, installed-app inventory, and Refresh Guard.
