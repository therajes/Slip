# Slip 2.8 engineering checklist

Baseline: 2.7.0. User confirmed live SMS-only sign-in works; preserve authentication stack and regression tests. Existing library version1, separate sidecars, Keychain/session references, reviewed queue and file leases stay compatible.

- [x] Inspect baseline documentation, manifests, native models/tests and core paths.
- [ ] Bounded ZIP analysis and typed offline signing evidence; distinguish source from issued profiles.
- [ ] Authoritative pre-transfer profile checks and exact-device outcome verification.
- [ ] Nonsecret operation journal and verification-only reconciliation.
- [ ] Native contextual readiness, device health, typed diagnostics and allowlist reports.
- [ ] UserNotifications with GUI-owned authorization and safe foreground actions.
- [ ] Additive protocol integration and legacy decoding; stale approval invalidation.
- [ ] Optional production signing/notarization tooling; no credentials committed.
- [ ] Run core Rust, vendored authentication, Swift suites, release build and verified DMG.

Dependencies/risks: account availability is Apple-confirmed only after provisioning. Unknown inventory cannot imply install failure or success. Source entitlements may differ from generated profiles. Security inspection must never execute imported binaries. Notification delivery, physical USB/Wi-Fi faults, Gatekeeper and production notarization require separate real-host/account validation. No portal mutation for informational preflight. No tag/release publication without approval; opening request approves source push only.


## Work breakdown and current evidence

- Core boundary: `ipa.rs` owns bounded offline archive evidence; `headless.rs` owns additive JSON-lines events, issued-profile checks and inventory verification. Authentication/SMS stack stays unchanged.
- Native boundary: existing Install readiness and App ID planner consume evidence; the operation coordinator remains the exclusive owner of install/refresh execution. Pending-outcome sidecar enables verification-only recovery without migrating library/Keychain data.
- Release boundary: five manifests already read 2.8.0 at inspection; `CFBundleVersion` retains the existing semantic-version policy. Production signing is explicitly opt-in; defaults retain local signing. Neither source push nor packaging creates a release tag.
- Current regression suites include AuthenticationFlowTests, CoreClientTests, AppLibraryTests, ReliabilityTests, IPADownloadTests, SourceFeedTests, RenewalRecoveryTests and TrustDiagnosticsTests, plus Rust IPA/verification and vendored SMS routing tests. The lead owns execution and final result recording.
- Implementation checklist entries remain open until integration and validation establish each requirement. Documentation does not certify the full definition of done. Real-host/device rows are tracked separately in `MANUAL_TEST_MATRIX_2.8.0.md`.

## Security and migration decisions

Archive/plist/feed bytes are untrusted; cap expansion and parser inputs, reject unsafe entry types and paths, use owned temporary directories, and never execute an imported binary. Generated provisioning data is authoritative only for the issued profile, not for future Apple availability. Support output must allowlist stable nonsecret fields. Persistent installation journals are private local state and must not enter support exports.

Existing library, renewal and session formats are retained. No migration requiring backup/rollback is introduced by release tooling. Production credentials are provisioned outside the repository in an isolated trusted runner keychain. `SLIP_PRODUCTION_SIGNING=1` fails closed on missing identity/profile or failed signing/notarization; default builds need neither. Pull requests do not opt into production signing. Real Gatekeeper, notification clicks and physical iPhone checks remain unverified until explicitly recorded.
