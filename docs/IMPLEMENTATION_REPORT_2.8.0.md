# Slip 2.8 implementation delivery

This is implemented source work, with remaining acceptance gaps listed below; it does not certify the full requested definition of done.

## Implemented

- Typed, versioned archive readiness evidence in the existing Install screen, expandable evidence/technical keys, source entitlement comparisons and authoritative issued-profile capability gate before transfer. Capability limitations require acknowledgement.
- Exact-target bundle inventory verification; unknown inventory stays pending. Private atomic operation journals include source hash/options; native sidecars preserve multiple pending operations. Startup reconciliation performs verification only, restores confirmed renewal/history metadata and retains unresolved records.
- Stable diagnostic codes/recovery cards and deterministic allowlist support reports; fallback compatibility remains.
- ZIP entry/expansion/metadata limits, unsafe path/type and duplicate/case collision rejection; source/download URL restrictions.
- Native notification coordinator with foreground permission and actions; production signing/notarization scripts opt in through secure runner configuration.
- Coordinated 2.8 manifests, release documentation and separate physical test matrix.

## Architecture and preservation

Additive JSON-lines fields preserve legacy decoding. Existing library, schedules, account sessions and Keychain references retain their formats; separate private operation sidecars require no destructive migration. Existing operation/file leases remain authoritative. Authentication sources were not rewritten. Owner-confirmed 2.7 live SMS behavior is baseline evidence, not a new live 2.8 test.

## Validation

- PASS: `cargo test --manifest-path src-tauri/Cargo.toml --locked --no-default-features --lib` — 43 tests.
- PASS: `cargo test --manifest-path src-tauri/Cargo.toml --locked -p isideload --lib` — 20 tests.
- PASS: `swift test --package-path native` — 90 tests, including final integration changes.
- PASS: `./native/build.sh` — optimized native/core app, local signature verification.
- PASS: `./native/create-dmg.sh native/build/Slip.app native/dist/Slip-2.8.0.dmg` — installer layout and image checks completed.
- PASS: `git diff --check`.
- NOT RUN: physical USB/Wi-Fi, Apple sign/provision/install, live 2.8 SMS, sleep/unplug fault injection, notification banner/click, production Developer ID/notarization/Gatekeeper.

## Screen walkthrough

Install: import the IPA, retain existing options/extensions, review readiness and expand observed/expected evidence. Signing presents issued-profile limitations for acknowledgement. Transfer completion becomes Installed only with device inventory evidence; otherwise Verify Device Installation is available. Activity: review typed recovery and preview sanitized support output. Auto Refresh: notification preference requests GUI authorization, pending outcomes require foreground verification. Existing library/update workflows remain in their current screens.

## Remaining acceptance gaps and risks

- Comprehensive fat Mach-O slice/framework alignment and all requested malformed/multi-extension/free-vs-paid fixtures are not complete. No fuzz campaign was run.
- External `security`/`codesign` inspection subprocesses still need deadlines. DNS rebinding and full endpoint resolution protections need further review.
- Device Health and App ID provenance/freshness UX remain narrower than the requested inspector. Notification categories exist, but all delivery triggers/click paths need physical validation.
- A job interrupted before a signed bundle identity remains pending for explicit review; rotation prevents it starving later records. Comprehensive boundary fault injection remains incomplete.
- Presence of a bundle proves presence, not that this operation installed a particular version/receipt. Crash reconciliation must be reviewed against existing-app/update cases on hardware.
- The typed error taxonomy includes compatibility message classification; full typed originating errors across every vendor path remain follow-up work.
- Production signing requires securely provisioned Developer ID private key and notarytool profile; none were supplied or exported. No release/tag publication.

Potential 2.9 dependencies: reliable iOS inventory version/receipt evidence, authoritative Apple resource freshness/quota APIs, and richer architecture/capability evidence. These are follow-up dependencies, not claims that the 2.8 acceptance gaps are complete.

## Changed paths

- `.github/workflows/build.yml`
- `CHANGELOG.md`
- `README.md`
- `docs/ENGINEERING_2.8.0.md`
- `docs/FEATURE_MATRIX.md`
- `docs/MANUAL_TEST_MATRIX_2.8.0.md`
- `docs/RELEASE_NOTES_2.8.0.md`
- `docs/RELEASING.md`
- `native/Info.plist`
- `native/Sources/SideloomNative/ActivityView.swift`
- `native/Sources/SideloomNative/AppIDPlanner.swift`
- `native/Sources/SideloomNative/AppModel.swift`
- `native/Sources/SideloomNative/AutoRefresh.swift`
- `native/Sources/SideloomNative/AutoRefreshView.swift`
- `native/Sources/SideloomNative/ContentView.swift`
- `native/Sources/SideloomNative/CoreClient.swift`
- `native/Sources/SideloomNative/DeviceAppsView.swift`
- `native/Sources/SideloomNative/DiagnosticRecoveryCard.swift`
- `native/Sources/SideloomNative/IPADownload.swift`
- `native/Sources/SideloomNative/InstallReadiness.swift`
- `native/Sources/SideloomNative/InstallView.swift`
- `native/Sources/SideloomNative/LibraryWorkspaces.swift`
- `native/Sources/SideloomNative/Models.swift`
- `native/Sources/SideloomNative/NotificationCoordinator.swift`
- `native/Sources/SideloomNative/PendingInstallOutcome.swift`
- `native/Sources/SideloomNative/SideloomApp.swift`
- `native/Sources/SideloomNative/SigningReadiness.swift`
- `native/Sources/SideloomNative/SourceFeeds.swift`
- `native/Sources/SideloomNative/TypedDiagnostics.swift`
- `native/Tests/SideloomNativeTests/TrustDiagnosticsTests.swift`
- `native/build.sh`
- `native/create-dmg.sh`
- `native/production-sign.sh`
- `package.json`
- `src-tauri/Cargo.lock`
- `src-tauri/Cargo.toml`
- `src-tauri/src/bin/sideloom-core.rs`
- `src-tauri/src/device.rs`
- `src-tauri/src/error.rs`
- `src-tauri/src/headless.rs`
- `src-tauri/src/ipa.rs`
- `src-tauri/tauri.conf.json`

- Report path: `docs/IMPLEMENTATION_REPORT_2.8.0.md`
