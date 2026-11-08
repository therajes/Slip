# Slip 2.8 implementation delivery

Implementation and local validation record. Live Apple/device and production-distribution validation are tracked separately from automated implementation checks.

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

- PASS: `cargo test --manifest-path src-tauri/Cargo.toml --locked --no-default-features --lib` — 48 tests.
- PASS: `cargo test --manifest-path src-tauri/Cargo.toml --locked -p isideload --lib` — 20 tests.
- PASS: `swift test --package-path native` — 96 tests, including final integration changes.
- PASS: `./native/build.sh` — optimized native/core app, local signature verification.
- PASS: `./native/create-dmg.sh native/build/Slip.app native/dist/Slip-2.8.0.dmg` — installer layout and image checks completed.
- PASS: `git diff --check`.
- NOT RUN: physical USB/Wi-Fi, Apple sign/provision/install, live 2.8 SMS, sleep/unplug fault injection, notification banner/click, production Developer ID/notarization/Gatekeeper.

## Screen walkthrough

Install: import the IPA, retain existing options/extensions, review readiness and expand observed/expected evidence. Signing presents issued-profile limitations for acknowledgement. Transfer completion becomes Installed only with device inventory evidence; otherwise Verify Device Installation is available. Activity: review typed recovery and preview sanitized support output. Auto Refresh: notification preference requests GUI authorization, pending outcomes require foreground verification. Existing library/update workflows remain in their current screens.

## Completed follow-up implementation

- Thin/fat32/fat64 Mach-O slice bounds, overlap, CPU table consistency and component alignment; explicit unknown for inconsistent slice entitlements.
- Fixed-tool inspection subprocesses have a 15-second deadline and 8 MiB output cap.
- Update verification compares expected signed version/build and persists pre-transfer inventory/acknowledgement. A preexisting same-version app without acknowledgement remains pending. Proven pre-transfer interruptions emit `noTransfer` and clear only their recovery sidecar.
- Device Health in Install and Accounts shows masked device identity, transport, OS, last seen, disconnect evidence and safe retest. Pairing/trust/Developer Mode remain Unknown without evidence.
- Team/account App ID provenance, freshness and quota caveats remain beside existing projections. Readiness groups stages, compares values side by side and filters removed-extension blockers. IPA inspector exposes known safe properties/components.
- Notification expiry policy throttles daily and captures delivery errors; actions stay foreground and do not bypass the operation lease.
- Feed/HTTPS download checks reject private, metadata, reserved and alternate numeric endpoints; feeds and redirects precheck DNS answers. DNS prechecks do not pin the eventual connection against a malicious rebinding server; URLSession/TLS protections remain required. Explicit local HTTP IPA imports retain existing compatibility.

## Validation requiring external evidence

Physical USB/Wi-Fi, Apple signing/provisioning, live 2.8 SMS, notification banner/click and production notarization remain NOT RUN. The owner-confirmed 2.7 SMS result is retained. No hardware success is inferred from fakes. Automated fixtures cover architecture/parser hostility, entitlement authorization, update evidence, interruption, removed extensions, health states, notification policy and privacy; no sustained fuzz campaign or exhaustive fault exploration is claimed.

Device CPU compatibility cannot establish runtime dynamic linkage. Reliable version/build evidence can be missing on some iOS inventory responses; such installs remain pending. Legacy journal records without enough evidence require review. Vendor errors retain a compatibility classifier where originating structured errors are unavailable.

Production signing needs a securely provisioned Developer ID private key and notarytool profile. They are not required for local builds, and none were exported. Potential 2.9 dependencies include stronger Apple quota/freshness APIs and trustworthy installation receipts on every supported iOS version.

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

## Installed app replacement

The existing `/Applications/Slip.app` was replaced with the validated 2.8.0 bundle using a staged copy and rename with rollback. Bundle identifier and local signing team match the previous installation. A private, ignored checkpoint under `native/build/checkpoint-2.8.0-*` retains the previous app, Application Support roots and preferences; Keychain was neither exported nor rewritten. Saved file contents matched before and after bundle replacement. GUI launch was observed: existing Apple Account selection and a network-connected iPhone were visible. This confirms launch/discovery UI, not an install or live authentication test.

Final build and DMG checks passed. The original local data remains in place. The initial network-policy test caught an alternate numeric address; after correction the full 96-test Swift suite passed.

## Follow-up changed paths

- `docs/ENGINEERING_2.8.0.md`
- `docs/IMPLEMENTATION_REPORT_2.8.0.md`
- `docs/RELEASE_NOTES_2.8.0.md`
- `native/Sources/SideloomNative/AccountsView.swift`
- `native/Sources/SideloomNative/AppIDPlanner.swift`
- `native/Sources/SideloomNative/AppModel.swift`
- `native/Sources/SideloomNative/DeviceHealth.swift`
- `native/Sources/SideloomNative/DiagnosticRecoveryCard.swift`
- `native/Sources/SideloomNative/IPADownload.swift`
- `native/Sources/SideloomNative/InstallReadiness.swift`
- `native/Sources/SideloomNative/InstallView.swift`
- `native/Sources/SideloomNative/NetworkEndpointPolicy.swift`
- `native/Sources/SideloomNative/NotificationCoordinator.swift`
- `native/Sources/SideloomNative/PendingInstallOutcome.swift`
- `native/Sources/SideloomNative/SigningReadiness.swift`
- `native/Sources/SideloomNative/SourceFeeds.swift`
- `native/Tests/SideloomNativeTests/NetworkEndpointPolicyTests.swift`
- `native/Tests/SideloomNativeTests/TrustDiagnosticsTests.swift`
- `src-tauri/src/error.rs`
- `src-tauri/src/headless.rs`
- `src-tauri/src/inspection_process.rs`
- `src-tauri/src/ipa.rs`
- `src-tauri/src/lib.rs`
