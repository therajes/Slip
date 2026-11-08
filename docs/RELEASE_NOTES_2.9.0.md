# Slip 2.9.0 — Discovery, Deployment & Architecture

- Browse explicitly approved AltStore-compatible sources and GitHub repositories in App Library. Search source-scoped results, review publisher claims and download domains, choose a specific asset, and inspect before installation review. No sources are preinstalled.
- Conditional feed caching preserves visible stale/offline status with 4 MB response and 32 MB index limits. GitHub offers explicit pagination up to ten pages. Optional image previews use bounded downloads, pixel budgets, downsampling and a bounded disk cache.
- Select multiple discovered iPhones as independent reviewed targets on the existing sequential queue. Each target freezes source/options hashes, account/team, effective bundle identity and exact UDID; missing destinations wait, uncertain outcomes reconcile, and failed targets require review before retry.
- AppModel now delegates cohesive account/device/workspace/install/refresh methods to MainActor coordinator components while retaining a single state owner. Additive protocol v3 correlates requests and ordered events, with legacy compatibility and stdin-only secret input.
- Settings offers .slipbackup metadata export, optional IPA copies, preview and conflict-preserving import. Checksummed, bounded JSON archive envelopes contain library/history/presets/subscriptions/catalog configuration. Existing IDs win conflicts; restored devices require revalidation and renewal stays disabled. Transaction rollback journals recover interrupted imports. Keychain/session/pairing material and iPhone private app data are excluded.
- Preserve 2.8 readiness, entitlement checks, verified/pending outcomes, diagnostics, native notifications, lease arbitration and working SMS authentication.

Requires Apple silicon and macOS 26+. Apple signing and free-account limits remain unchanged. Deployments remain sequential under the existing global operation lease. Catalog identity and compatibility are publisher claims until IPA inspection; unknown GitHub bundle IDs require explicit review. Backups store portable path hints, not transferable device trust or authentication. Optional IPA copies are capped at 128 MiB each and 256 MiB total; use metadata export for larger libraries.

Physical multi-device installs, live 2.9 Apple/SMS, SIGKILL on hardware, Instruments measurements, clean-user migration and production notarization are not claimed. See the implementation report for actual automated results. Default GitHub installers are ad-hoc signed and not Apple-notarized; production signing remains opt-in with securely provisioned credentials.

Local automated validation passed: 48 core Rust tests, 20 vendored authentication tests, 113 Swift tests, native optimized app build and verified DMG packaging.
