# Slip 2.4.0 — App Library, Installation Queue, and Liquid Glass

Slip 2.4.0 introduces the persistent App Library and batch installation queue, upgrades the interface to native macOS 26 Liquid Glass chrome, adds a kernel-leased operation coordinator and disk-backed download task manager, and expands automated regression test coverage to 54 Swift tests.

## Highlights

- **App Library (⌘6)**: Save and restore IPA preparation workspaces across launches. Saves app bundle metadata, icon references, extension selections, advanced plist configurations, target Apple accounts, and paired iPhones to private owner-only storage (`workspaces-v1.json`). Re-inspects IPAs automatically on launch without initiating unwanted signing.
- **Batch Installation Queue**: Import batches of IPAs via drag-and-drop or file selection in Finder order. Individual apps enter a "Review required" state to inspect options before queuing. The queue installs apps sequentially using frozen option snapshots and safely stops on the first failure or cancellation with "Review & Retry".
- **macOS 26 Liquid Glass Interface**: Native SwiftUI Liquid Glass chrome utilizing Droppy Code 1.7.0 `glassEffect(in:)` with a 12% theme wash, 1-point rims, transparent page wrappers, and floating navigation capsules (⌘1–⌘6). Targets macOS 26.0+ compiled against macOS SDK 27.2 / Xcode 27.2, with full support for system Reduce Motion and Reduce Transparency accessibility settings.
- **Kernel File Lease Operation Coordinator**: Cross-process and intra-process operation coordination using POSIX file leases (`flock`). Synchronizes signing, installation, and background refresh between the GUI application and LaunchAgent worker. Leases release immediately on process exit, eliminating arbitrary 20-minute timeouts while protecting schedule changes with atomic read/modify/write transactions.
- **Download Task Manager**: Disk-backed `URLSessionDownloadTask` pipeline providing live byte counts, percentage, transfer speed, and cancellation support. Retries transient transport failures and HTTP 429/50x responses up to three times with bounded backoff, while rejecting plaintext HTTP redirects and URL credentials.
- **54 Automated Swift Tests**: Comprehensive test suite across 7 modules validating workspace persistence, batch import ordering, queue failure halting, cancellation recovery, file lease concurrency, URL streaming, 2FA challenge presentation, and window focus without requiring live Apple credentials or connected hardware.

## What changed

### App Library & Workspaces
- Added the App Library panel in floating navigation (⌘6).
- Opening any verified IPA automatically creates a library entry with its name, bundle ID, icon path, extension choices, custom plist properties, selected account, and target device.
- Saves changes with debounced persistence and updates entries before app switching or quitting.
- Original IPA files remain referenced in their existing locations; large binaries are never duplicated and passwords/tokens remain strictly in Keychain.
- Added "Locate IPA…" to relink files that have moved or been renamed after bundle identity verification.
- Modified source file stamps invalidate queued review state to ensure out-of-date settings are not applied.
- Corrupt or newer library file versions are preserved rather than overwritten.

### Batch Installation Queue
- Drag or select multiple IPAs to queue them in Finder order; duplicate paths within a batch are automatically deduplicated.
- Each app begins with a visible "Review required" badge until target account, device, and signing options are verified and saved.
- Pending queue entries can be manually reordered earlier or later, or removed individually.
- "Install Queue" activates when all pending items are reviewed, processing one app at a time with a snapshot of reviewed choices.
- Failures or user cancellations stop the queue immediately to prevent repeated errors, leaving subsequent apps pending and offering "Review & Retry".
- Interrupted installations revert to "Review required" on next launch without assuming whether incomplete transfers reached the device.

### macOS 26 Liquid Glass Interface
- Updated interface chrome to match Droppy Code 1.7.0 Liquid Glass styling with native `glassEffect(in:)`, 12% theme wash, and 1-point boundary rims.
- Set minimum deployment target to macOS 26.0, compiling against macOS SDK 27.2.
- Floating capsule navigation bar aligns with window controls and supports keyboard navigation (⌘1 through ⌘6).
- Preserves full accessibility behavior: Reduce Motion disables animated presses and preview transitions, while Reduce Transparency and high contrast fall back to solid neutral surfaces.

### Kernel File Lease Operation Coordinator
- Added `FileLease` and `OperationCoordinator` utilizing kernel-level `flock` locks on operation lock files.
- Ensures only one signing or refresh operation executes at any time across the foreground app and background LaunchAgent worker.
- Active leases remain held for the full duration of real work; process exits or terminations automatically release locks immediately.
- Schedule persistence uses atomic read/modify/write file lease transactions to prevent race conditions, preserve paused recipes, and prevent resurrection of deleted schedules.

### Download Task Manager
- Large IPAs stream directly to disk using `URLSessionDownloadTask` with ephemeral configurations.
- Displays progress with bytes received, total expected bytes, transfer speed, and progress fractions.
- Transient transport drops and HTTP 429/500/502/503/504 errors retry automatically up to three times with exponential backoff.
- Cancellation instantly halts active connections, cancels scheduled retry timers, and purges partial temporary files without clearing active workspace configurations.
- Strict input sanitization rejects URLs with embedded credentials or insecure HTTP protocol downgrades.

### Test Suites & Validation
- Swift test suite expanded to 54 passing tests across 7 test modules:
  - `AppLibraryTests` (9 tests): workspace restoration, batch imports, source file stamp changes, sequential queue execution, failure handling, cancellation, reordering, and permission checks.
  - `ReliabilityTests` (13 tests): kernel file lease contention, timeout elimination, cross-process exit release, schedule merging, and attention state management.
  - `IPADownloadTests` (6 tests): streaming progress calculation, HTTP error codes, retry delays, cancellation cleanup, and redirect policy.
  - `CoreClientTests` (6 tests): IPC pipe handling, error decoding, cancellation, and exit cleanup.
  - `AuthenticationFlowTests` (8 tests): inline 2FA challenges, method switching, code validation, and error recovery.
  - `AnisetteServerDirectoryTests` (9 tests): remote server filtering, caching fallbacks, and metadata validation.
  - `WindowFocusTests` (3 tests): window hosting, field editor keyboard focus, and resize tracking.
- All integration tests use loopback fixtures and synthetic responses; no live Apple accounts or physical hardware are modified.

## Important limits

- Slip requires macOS 26.0 or newer.
- Slip does not bypass Apple's seven-day free-profile certificate lifetime or the three-app active sideloading limit per device.
- Automatic background refresh requires this Mac to remain awake, valid Keychain credentials, and a reachable paired iPhone.
- The downloadable build is development-signed and not notarized.
