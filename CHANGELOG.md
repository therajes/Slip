# Changelog

## 2.9.0 — 2026-11-08

- Add opt-in source catalogs, provenance, conditional offline cache and reviewed downloads.
- Extend sequential queue with durable exact-device deployment targets and review identities.
- Extract MainActor coordinators and add correlated ordered protocol v3 events.
- Add previewable checksummed metadata backups with optional bounded IPA copies and rollback.
- Preserve 2.8 signing intelligence, outcome verification and SMS authentication.


## 2.8.0 — 2026-11-08

- Add versioned signing-readiness evidence and generated-profile checks before transfer.
- Require device-scoped inventory confirmation and preserve verification-pending outcomes for reconciliation.
- Add typed diagnostics, contextual recovery and allowlist-based support reports.
- Bound archive inspection and reject hostile paths, duplicate entries, special files and excessive expansion.
- Replace script notifications with native UserNotifications and foreground recovery actions.
- Add opt-in Developer ID/Hardened Runtime/notarization tooling while retaining local builds.
- Preserve the owner-confirmed working SMS sign-in flow and existing library/Keychain formats.

See docs/RELEASE_NOTES_2.8.0.md for validation and remaining limits.

## 2.7.0 — 2026-11-06

- Fix SMS-only Apple authentication routing, real trusted-number selection and duplicate destination requests.
- Keep SMS prompts and code validation consistent across sign-in and installation.
- Follow per-app GitHub releases and AltStore source feeds, with version, release notes and compatibility details.
- Prepare validated updates with saved customizations and explicit installation review.
- Add cached IPA artwork, saved/installed version history and reusable customization presets.
- Add optional hash-verified managed IPA storage, usage reporting and protected move-to-Trash cleanup.
- Update the repository gallery, release documentation and versioned DMG.


## 2.6.0 — 2026-11-05

- Read expiry from signed provisioning profiles; label legacy and fallback deadlines as estimates.
- Plan new and reused App IDs across the selected account's ready queue and kept extensions.
- Resume supported downloads after validating server identity; reject changed files.
- Add pause-after-current, cancel-current and stop-queue controls with reviewed retries.
- Check due renewals after wake and offer optional quiet notifications.
- Add actionable Activity diagnostics and a previewable redacted support report.
- Refresh layered icon materials, screenshots, release documentation and the versioned DMG.
- Avoid reverse DNS during local download-test server startup, fixing CI fixture timeouts.

## 2.5.0 - 2026-11-03

### Changed

- Workspace edits now use targeted, debounced autosaving with serialized atomic writes, unchanged-snapshot detection, and revision ordering. Switching workspaces and quitting preserve the latest edits; a save failure keeps the app open with an explanation.
- Installation and download progress update independently of the workspace. Lazy library and queue rows, background file checks, and bounded artwork caches reduce repeated work during navigation.
- USB notifications, app activation, and Mac wake trigger debounced device discovery. Paired network discovery runs while the app is active and pauses in the background or during workspace operations.

### Fixed

- Inventory results and errors are scoped to the physical iPhone and request generation, preventing stale responses from appearing after a device switch.
- Renewal actions, managed-app badges, uninstall confirmations, and post-uninstall recipe cleanup match the selected iPhone as well as the bundle ID.
- Transient discovery errors preserve the last known connection; successful empty discovery clears disconnected devices while retaining the intended target for reconnection.

The library format, existing renewal times, and authentication core remain unchanged. See the [2.5.0 release notes](docs/RELEASE_NOTES_2.5.0.md) for details and validation limits.

## 2.4.0 - 2026-11-01

### Added

- **App Library**: Added persistent workspace management in the floating navigation panel (⌘6). Saves app metadata, bundle identifiers, icon references, extension selections, plist customizations, target accounts, and destination iPhones in `~/Library/Application Support/app.sideloom.native/Library/workspaces-v1.json` with owner-only (0700) permissions. Automatically restores the last workspace on launch without initiating signing, validates IPA file stamps, and offers a "Locate IPA…" action for moved or missing files.
- **Installation Queue**: Added batch IPA import via file picker or drag-and-drop preserving Finder order. Unreviewed imports begin in "Review required" state; once reviewed with account and destination choices, apps can be reordered or removed. "Install Queue" executes sequentially using frozen option snapshots and halts on the first failure or cancellation with "Review & Retry" rather than proceeding with invalid states.
- **Native macOS 26 Liquid Glass Interface**: Native SwiftUI Liquid Glass window chrome using Droppy Code 1.7.0 `glassEffect(in:)` with 12% theme wash, 1-point rims, and floating navigation capsules (⌘1–⌘6). Built for macOS 26+ using macOS SDK 27.2 / Xcode 27.2, featuring responsive layouts and full support for system Reduce Motion, Reduce Transparency, and contrast preferences.
- **Kernel File Lease Operation Coordinator**: Added `FileLease` and `OperationCoordinator` using kernel file leases (`flock`) to serialize signing, installation, and refresh tasks across the main GUI app and background LaunchAgent worker. Leases release automatically on process termination without arbitrary 20-minute timeouts, and schedule modifications are guarded by atomic read/modify/write transactions.
- **Download Task Manager**: Added disk-backed `URLSessionDownloadTask` manager supporting real-time transfer progress (received/total bytes, transfer speed, and progress fraction), cancellation, and bounded exponential retry backoff (up to 3 attempts) for transient network drops and HTTP 429/50x errors. Insecure HTTP redirects and credentials in URLs are strictly rejected.
- **Automated Test Suites**: Expanded test coverage to 54 passing Swift unit and integration tests across 7 suites (`AppLibraryTests`, `ReliabilityTests`, `IPADownloadTests`, `CoreClientTests`, `AuthenticationFlowTests`, `AnisetteServerDirectoryTests`, and `WindowFocusTests`), verifying workspace persistence, queue serialization, file lease safety, download mechanics, and UI focus without live Apple account mutation.

### Changed

- Minimum deployment target is now macOS 26.0 (linked against macOS SDK 27.2).
- Background worker renewal checks run every 15 minutes and mark interactive 2FA requirements as "Needs attention" without entering unattended retry loops.
- Interrupted installations revert to "Review required" state on application restart rather than assuming device transfers completed.

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
