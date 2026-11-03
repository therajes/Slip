# Slip 2.5.0 — Responsiveness and device correctness

This release updates the existing native app and keeps its bundle identifier, signing identity, Keychain service, version-1 library format, renewal schedule format and authentication core. The approved backdrop and icon are unchanged.

## Responsiveness

- Workspace edits trigger targeted, debounced autosaving. Byte progress, activity messages and unrelated model changes no longer schedule a library save.
- A serial actor performs JSON validation, encoding and atomic disk writes. Unchanged snapshots are skipped, preserving the existing file bytes; revision numbers prevent an older task from overwriting a newer state.
- Switching workspaces still captures choices immediately. Quitting waits asynchronously for pending writes and captures edits made during the wait. A save failure keeps the app open with an explanation.
- Installation and download progress use a separate observable object. Frequent percentage changes update the progress controls without invalidating the entire workspace.
- The library and queue use lazy rows. Search results are sorted once per update rather than once again for every divider. Source-file availability checks run off the main actor.
- App artwork is decoded and downsampled in background tasks, then reused through a bounded memory cache. IPA artwork extraction also uses a bounded disk cache keyed by the source file stamp, version and path. Inspection still runs before installation; this cache only avoids repeating artwork work.

## Device correctness

- Inventory requests carry a generation and physical device identity. Late results and errors from another iPhone are discarded, including an A → B → A switch.
- Inventory and selections clear when the physical iPhone changes. An uninstall confirmation is tied to the iPhone on which it was requested.
- Selected renewal actions, managed-app badges and post-uninstall schedule cleanup match both the bundle ID and device UDID. Removing an app on one phone cannot remove another phone’s renewal recipe through this path.
- USB connect/disconnect notifications trigger debounced discovery. Activation and waking the Mac also refresh discovery. Paired network-device discovery runs every 30 seconds while the app is active; periodic polling pauses in the background. Discovery is skipped during active workspace operations.
- A transient discovery error preserves the last known connection instead of announcing a false disconnection. A successful empty discovery clears disconnected devices while retaining the user’s intended target for reconnection.

## Data preservation and installation

The update is applied to the existing `/Applications/Slip.app` directory. Only the native executable, version metadata and code-signature resource seal are updated. No uninstall or library migration is performed. The signing certificate and designated requirement match the prior app, retaining its Keychain identity.

Private backups are kept locally under `native/build/update-2.5/private-backup`, protected by an owner-only parent directory. Checks compare the library, renewal schedule and existing Core session/account files before and after the update. Keychain passwords are neither exported nor rewritten by the update procedure. Existing source IPAs are not moved, copied or deleted.

## Validation and limits

68 Swift tests pass, including 14 new checks for device races, device-specific renewal removal, rejected stale uninstall confirmations, quiet discovery, coalesced device events, targeted autosaving, latest-edit flushing, out-of-order disk revisions, preservation of older library bytes, corrupt-file preservation and image-cache reuse.

A stress check sends 1,000 stage, fraction and download-progress updates and observes zero whole-model invalidations and unchanged library bytes. A rapid-edit check confirms 100 edits produce one disk write and retain the final text.

Live checks cover the preserved two-app library, unchanged renewal times, selected saved account, navigation and read-only iPhone app inventory loading. No Apple sign-in, certificate operation, IPA installation or live renewal is performed. USB disconnect/reconnect races are covered with local fixtures; no cable unplug is required during validation.

SwiftUI Instruments traces are recorded for inspection. The short interactive traces are not a controlled benchmark and do not support a percentage speedup or universal frame-rate claim. The concrete gains above are verified by scoped regression checks.

Built with public Xcode 27.2, macOS SDK 27.2 and a macOS 26.0 minimum. Profile-expiry changes, quota planning, app-update feeds and storage management remain separate future releases; 2.5 does not reschedule existing apps.
