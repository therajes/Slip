# Changelog

## 2.0.0 — 2026-08-11

### Added

- Active App ID inventory with Apple-reported quota, reset time, developer team, and app/extension context.
- Cross-process iPhone operation coordination so foreground installs, inventory actions, uninstalls, Wi-Fi setup, and background refreshes cannot collide.
- Native ARM64 GitHub build, test, audit, DMG, checksum, and release workflow.

### Changed

- Removed the Apple Account profile-photo feature; compact generated-initial identity cards cannot distort the account layout or leave local image residue.
- Reduced Slip to its maintained native SwiftUI application and focused Rust core, removing the dormant Tauri/React and cross-platform build surface.
- Updated the signing and device stack and reworked process I/O to stream output continuously, eliminating large-icon inventory deadlocks.
- Refresh Guard now merges schedule updates atomically, preserves paused state during manual refresh, and verifies its launch agent after installation.

### Fixed

- Restored installed-app loading and resilient artwork retrieval for every compatible app, with bounded icon payloads and graceful fallbacks.
- Removed duplicate iPhone Apps checkboxes and made selection actions device-specific and explicit.
- Prevented canceled installs from reporting false failures or releasing their device lock before the core process exits.
- Added strict IPA path, size, entry-count, plist, icon, Mach-O, identity, and custom-value validation.
- Hardened URL downloads with ephemeral networking, timeouts, size limits, cleanup, and owner-only storage.
- Zeroed Apple Account passwords in the Rust core immediately after authentication and kept errors free of credential data and source paths.

### Performance

- Reuses the prepared and compressed IPA across transfer retries instead of rebuilding it.
- Drains core output concurrently and caps inventory/icon buffers, keeping large app libraries responsive without unbounded memory growth.

## 1.1.2 — 2026-08-11

### Added

- Added the real on-device artwork for every iPhone Apps inventory row, read from iOS SpringBoard with a resilient initials fallback when an icon is unavailable.

### Fixed

- IPA artwork extraction now follows `CFBundleIcons` and `CFBundleIconFiles`, so valid icons with names such as `logo_youtube…` appear instead of working only for filenames containing “icon.”
- Apple Account profile photos are center-cropped, downsampled, and hard-constrained to the avatar frame instead of expanding the account view.
- Removed the checkbox-like generic app placeholder from iPhone Apps, leaving one explicit selection checkbox per row and a small refresh badge only for Slip-managed apps.

### Performance

- Reuses one SpringBoard connection while retrieving the installed-app icon set and keeps icon failure non-blocking, preserving a fast and reliable inventory load.

## 1.1.1 — 2026-08-09

### Added

- Added an explicit iPhone-app selection action bar with Select Visible, Clear, Copy IDs, Refresh, and Uninstall actions.
- Added paired-device uninstallation through Apple’s Installation Proxy with partial-failure reporting and a destructive confirmation that explains local-data removal.
- Added an animated, icon-like Liquid Glass iPhone preview with an intentionally empty neutral display, a single settling USB insertion for wired devices, and a monochrome glass Wi-Fi indicator for network devices.
- Added a shared dimensional symbol treatment across navigation, status pills, card headers, actions, app rows, and empty states, with neutral highlights and restrained depth shadows.
- Added Apple Account identity profiles with dimensional avatars, editable local profile photos, inferred names for existing credentials, and automatic verified-name capture from Apple after authentication.

### Fixed

- Replaced ambiguous selectable inventory rows with visible checkboxes and selected-row styling.
- Matching Auto Refresh recipes are removed after an app is successfully uninstalled, preventing an intentionally removed app from being reinstalled by the background guard.
- Refresh is enabled only when the selection includes apps already managed by Slip, with a clear explanation otherwise.
- The Destination card now leads with the iPhone’s personal device name and shows its detected model in a smaller parenthetical label.
- The Dynamic Island and notch now inherit the neutral glass rim treatment instead of appearing as a mismatched black element.

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
