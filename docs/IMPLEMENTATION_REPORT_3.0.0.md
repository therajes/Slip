# Slip3.0 local acceptance report

Baseline19771a8/2.9.2, user-confirmed. Preserved the camelCase Boolean capability acknowledgement fix and2.9.2 automatic acknowledgement. Exact pipe regression covers bothtrue/false; SMS semantics untouched.

## Implemented

Shared renewal eligibility/status engine; additive source/options/icon approvals, pending identities, retries/reasons and verified evidence; global leases serialize worker/GUI. Unknown transfers require verification, pretransfer failures can safely retry. Explicit source review for legacy schedules, noninteractive background Keychain access, bounded private attempt history.

Optional same-model NSStatusItem companion, coalesced wake/network/discovery/due hints,900second LaunchAgent fallback, soft hostpower policy. Separate menu/login/background/pause/notifications/quiet settings; assurance checks actual registration, sourcehashes, credentials, discovery/lease status. Native quiet/deduped notifications route foreground. First-run/offline guide preserves native window hosting.

413 extracted English localization keys, localized diagnostic captions, English fallback for unreviewed languages. Exact app/core/helper version/signature/arm64 verification, secure opt-in production signing, provenance/SPDX lock inventory/scanner status tooling. Current Sparkle integration is deferred pending controlled signed feed/key and production-chain validation; manual updates remain explicit. macOS26arm64 support retained.

## Results

| Command/check | Result |
| --- | --- |
| cargo test --manifest-path src-tauri/Cargo.toml --locked --no-default-features --lib | PASS48 |
| cargo test --manifest-path src-tauri/Cargo.toml --locked -p isideload --lib | PASS20 |
| swift test --package-path native | PASS125 final |
| ./native/build.sh | PASS |
| native/release-verify.sh native/build/Slip.app | PASS versions/signatures/arm64 |
| ./native/create-dmg.sh native/build/Slip.app native/dist/Slip-3.0.0.dmg | PASS image checksum/installer layout |
| git diff --check | PASS |
| Installed app launch | PASS observed existing account selection and USB discovery |
| Physical refresh/SMS/multiday/device faults | NOT RUN; user acceptance pending |
| Production notarization/cleanMac Gatekeeper/Instruments | NOT RUN |

## Local replacement and migration

Replaced /Applications/Slip.app with3.0.0. Bundle identity and signing team match2.9.2. Private ignored checkpoint native/build/checkpoint-3.0.0-* retains previous app/data/preferences. File-content hashes matched immediately before/after replacement; Keychain was not exported or changed. Launch can legitimately update ordinary local app state. Existing libraries/catalog/backups/session references retain formats; renewal fields are additive. Legacy approved source hashes are unavailable and require explicit review once. No push/tag/release performed; await user flag.

## Acceptance walkthrough

1. Check library, accounts, presets, subscriptions, saved IPAs and renewal recipes remain available.
2. Auto Refresh → Renewal Assurance → approve the saved source once when requested → Check Background Readiness.
3. Refresh an existing app. Capability differences retain2.9.2 autoaccept and must not falsely cancel. Confirm install/version/expiry or explicit pending state.
4. Enable optional menu in Settings; Open Slip/Install IPA/Refresh Due/Pause and close/reopen window. Verify pause and independent GUI-login/background switches.
5. Disconnect/reconnect USB, try paired Wi-Fi, sleep/wake, no network and overlapping manual refresh. Ensure waiting/pending reasons and no duplicate install.
6. Test notifications/quiet hours and foreground action, SMS sign-in if desired, catalog and backup roundtrip. Never share credentials/codes.

## Unresolved gates, ranked

P0 dependency review: cargo-audit reported15 lockfile advisories (exit1); no clearance claimed. See SECURITY_REVIEW_3.0.0.md for IDs/patch ranges. OSV was not installed. Triage feature reachability and compatible fixes before public release.

P0 distribution: DeveloperID private key/team/notary profile are not configured or validated; clean-machine validation is pending; no production notarization claim. Unattended signed self-update cannot ship without authenticated key/feed/provenance chain. Local test launch recommended; public release waits for user approval and accurate signing label.

P1 validation: physical multi-day/two-device/clock/DST/disk-full/kill/locked-phone/hand-off tests and performance measurements remain user/hardware gates. Engine supports Retry-After lowerbounds but current Apple error IPC provides no authoritative header; none is invented. Full localization/pluralization/VoiceOver/RTL review is incomplete; target languages have0 reviewed translations and useEnglish. Existing dynamic/raw older-core messages remainEnglish.

P2 refinement: measure launch/menuidle/wakeups/large-library behavior before claims; broader domainactor extraction and verified olderOS experiments remain future work. No before/after performance figures or success percentages are asserted.

Artifacts: native/build/Slip.app, native/dist/Slip-3.0.0.dmg; local provenance/SBOM/checksums in native/dist. No release publication. Supported:Apple-silicon macOS26+, authorized personal iPhone overUSB/pairedWi-Fi, free/paid Apple teams withinApplelimits. No iPhone-only perpetual signing, private app-data restore, JIT/tweak, Intel/Windows/AppleTV promises.

## Exact changed paths

- `.github/workflows/build.yml`
- `CHANGELOG.md`
- `docs/ENGINEERING_3.0.0.md`
- `docs/FEATURE_MATRIX.md`
- `docs/LOCALIZATION_3.0.0.md`
- `docs/MIGRATION_3.0.0.md`
- `docs/RELEASE_NOTES_3.0.0.md`
- `docs/RELEASING.md`
- `docs/SUPPORT_MATRIX_3.0.0.md`
- `docs/UPDATER_3.0.0.md`
- `docs/USER_MANUAL_3.0.0.md`
- `native/AnisetteHelper.m`
- `native/Info.plist`
- `native/Package.swift`
- `native/Sources/SideloomNative/AppModel.swift`
- `native/Sources/SideloomNative/AppearanceController.swift`
- `native/Sources/SideloomNative/AssuranceView.swift`
- `native/Sources/SideloomNative/AutoRefresh.swift`
- `native/Sources/SideloomNative/AutoRefreshView.swift`
- `native/Sources/SideloomNative/CompanionCoordinator.swift`
- `native/Sources/SideloomNative/CompanionPreferences.swift`
- `native/Sources/SideloomNative/DeviceConnectionMonitor.swift`
- `native/Sources/SideloomNative/InstallCoordinator.swift`
- `native/Sources/SideloomNative/KeychainStore.swift`
- `native/Sources/SideloomNative/Localization/Localizable.xcstrings`
- `native/Sources/SideloomNative/Localization/en.lproj/Localizable.strings`
- `native/Sources/SideloomNative/ManagedInstallationsRepository.swift`
- `native/Sources/SideloomNative/NotificationCoordinator.swift`
- `native/Sources/SideloomNative/OnboardingGuide.swift`
- `native/Sources/SideloomNative/PendingInstallOutcome.swift`
- `native/Sources/SideloomNative/RefreshCoordinator.swift`
- `native/Sources/SideloomNative/RenewalEngine.swift`
- `native/Sources/SideloomNative/RenewalHistory.swift`
- `native/Sources/SideloomNative/SideloomApp.swift`
- `native/Sources/SideloomNative/TypedDiagnostics.swift`
- `native/Tests/SideloomNativeTests/CompanionPolicyTests.swift`
- `native/Tests/SideloomNativeTests/CoreClientTests.swift`
- `native/Tests/SideloomNativeTests/ProductionPolicyTests.swift`
- `native/Tests/SideloomNativeTests/RenewalEngineTests.swift`
- `native/build.sh`
- `native/localization-audit.py`
- `native/production-sign.sh`
- `native/release-evidence.py`
- `native/release-verify.sh`
- `package.json`
- `src-tauri/Cargo.lock`
- `src-tauri/Cargo.toml`
- `src-tauri/src/headless.rs`
- `src-tauri/tauri.conf.json`
- `docs/IMPLEMENTATION_REPORT_3.0.0.md`

- `docs/SECURITY_REVIEW_3.0.0.md`
