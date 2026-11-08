# Slip 2.9 delivery report

## Architecture and migration

MainActor AppModel remains the sole view state owner, with account/device/IPA/install/refresh method bodies extracted to coordinator components. Existing IO actors and file leases remain in place; no parallel signing claim. Protocol v3 fields are additive and correlate request/operation/ordered events while accepting legacy events. Secrets remain on stdin.

The existing library version 1 adds optional deployment snapshots. Source/options hashes, account/team, exact UDID and effective identity gate review. Targets execute sequentially; global kernel arbitration also excludes LaunchAgent refresh. Unknown results require reconciliation before review/retry. Legacy targets remain readable.

Catalog indexes are opt-in, source-scoped and bounded; source claims remain unverified. Conditional fetches preserve stale data, explicit release selection avoids ambiguous assets. GitHub pagination is bounded to 200 releases; image previews require explicit consent and apply byte/pixel/disk limits. Metadata never silently changes an installed payload.

Backup schema 1 is a checksummed JSON archive envelope (.slipbackup), not an unrestricted ZIP extractor. It allowlists typed library/history/presets/subscriptions/catalog configuration and optional regular IPA copies. Import merges IDs, keeps local conflicts, discards queue approvals and disables renewal/device bindings. Atomic file replacements use a durable rollback manifest recovered before startup library loading. No Keychain/session/pairing migration or export. IPA inclusion caps:128 MiB/file,256 MiB total; envelope360 MiB. Use metadata-only for larger IPAs.

## Command results

| Command | Result |
| --- | --- |
| cargo test --manifest-path src-tauri/Cargo.toml --locked --no-default-features --lib | PASS:48 |
| cargo test --manifest-path src-tauri/Cargo.toml --locked -p isideload --lib | PASS:20 |
| swift test --package-path native | PASS:113 after integration |
| ./native/build.sh | PASS:release app and local signature |
| ./native/create-dmg.sh native/build/Slip.app native/dist/Slip-2.9.0.dmg | PASS:DMG checksum and installer layout verified |
| git diff --check | PASS |

Intermediate Swift suites passed 107,110 then113 tests as extractions/integration progressed. A new backup test exposed a missing clean-user Library directory; fixed before the final passing run. No physical result is inferred from tests.

## User journeys

- Library → Browse Sources → explicitly subscribe → inspect publisher/domain/release details → choose asset → download/IPA inspection → Install readiness → reviewed queue → verified device-scoped outcome.
- Install → select multiple discovered targets → Add to Queue → review each device result. Missing targets wait; failure stops the sequential queue. Retry Failed Targets returns only failed/cancelled entries to review.
- Settings → export metadata (optional IPA inclusion) → preview import → keep local conflicts → imported workspaces require locating/inspection/authentication and target review.

## Hardware tasks and warnings

NOT RUN: live 2.9 SMS/Apple signing, physical two-device/disconnection/SIGKILL/sleep tests, clean-user macOS import, VoiceOver/keyboard UI walkthrough, Instruments launch/scroll/idle/memory profiling, production notarization. Known working SMS semantics were preserved; the user's 2.8 confirmation is not a 2.9 physical test.

Discovered devices are not assumed trusted; core handshake remains authoritative. Capability/quota checks depend on Apple and are not future signing guarantees. Publisher identity is not certified. DNS prechecks retain the documented rebinding limitation. Backup rollback may need free disk space to finish after disk exhaustion. External source paths are hints. The import UI shows counts and conflict policy rather than per-field merge editing. Queue continues to stop on failure; automatic continuation is not enabled. No unattended new-code downloads/installs or periodic catalog polling is enabled.

Recommended 3.0 work: stable domain service APIs beyond MainActor extensions, stronger connection pinning, authoritative signed installation receipts, measured large-catalog profiling, deeper destructive-fault/disk-full automation and hardware validation across iOS/account types. These are limitations/follow-ups, not fabricated test results.

## Changed paths

- `CHANGELOG.md`
- `README.md`
- `docs/ENGINEERING_2.9.0.md`
- `docs/FEATURE_MATRIX.md`
- `docs/MIGRATION_2.9.0.md`
- `docs/RELEASE_NOTES_2.9.0.md`
- `native/Info.plist`
- `native/Sources/SideloomNative/AccountCoordinator.swift`
- `native/Sources/SideloomNative/AppLibrary.swift`
- `native/Sources/SideloomNative/AppLibraryView.swift`
- `native/Sources/SideloomNative/AppModel.swift`
- `native/Sources/SideloomNative/AppUpdates.swift`
- `native/Sources/SideloomNative/AppearanceController.swift`
- `native/Sources/SideloomNative/BackupRepository.swift`
- `native/Sources/SideloomNative/BackupView.swift`
- `native/Sources/SideloomNative/CatalogArtwork.swift`
- `native/Sources/SideloomNative/CatalogBrowser.swift`
- `native/Sources/SideloomNative/CatalogRepository.swift`
- `native/Sources/SideloomNative/CoreClient.swift`
- `native/Sources/SideloomNative/DeploymentJob.swift`
- `native/Sources/SideloomNative/DeploymentQueueCoordinator.swift`
- `native/Sources/SideloomNative/DeviceCoordinator.swift`
- `native/Sources/SideloomNative/IPAWorkspaceCoordinator.swift`
- `native/Sources/SideloomNative/InstallCoordinator.swift`
- `native/Sources/SideloomNative/InstallView.swift`
- `native/Sources/SideloomNative/LibraryWorkspaces.swift`
- `native/Sources/SideloomNative/Models.swift`
- `native/Sources/SideloomNative/PendingInstallOutcome.swift`
- `native/Sources/SideloomNative/RefreshCoordinator.swift`
- `native/Sources/SideloomNative/SourceFeeds.swift`
- `native/Tests/SideloomNativeTests/ArchitectureTests.swift`
- `native/Tests/SideloomNativeTests/BackupTests.swift`
- `native/Tests/SideloomNativeTests/CatalogArtworkTests.swift`
- `native/Tests/SideloomNativeTests/CatalogTests.swift`
- `native/Tests/SideloomNativeTests/DeploymentJobTests.swift`
- `package.json`
- `src-tauri/Cargo.lock`
- `src-tauri/Cargo.toml`
- `src-tauri/src/headless.rs`
- `src-tauri/tauri.conf.json`

- `docs/IMPLEMENTATION_REPORT_2.9.0.md`
