# Slip 3.0 engineering

Baseline:19771a8, shipped 2.9.2, owner confirmed. Preserve typed JSON capability acknowledgement and 2.9.2 autoaccept behavior, SMS semantics and verified outcomes. Do not revert to2.9.0.

Lifecycle: SwiftUI Settings plus custom AppKit SlipWindow/delegate. Optional NSStatusItem uses existing AppModel. Worker runs --refresh-due without GUI/account enumeration. MainActor/coordinator → global kernel operation lease → repository write lease; release write locks before device/account IO. One sequential signing owner across GUI/worker/menu.

Keep900-second LaunchAgent fallback. Event hints coalesce; discovery is not proof of trust. Add optional source/options/icon approval hashes, pending operation identity, retry/reason/next-eligible/verification evidence. Legacy missing approvals require explicit source review. Unknown transfer requires reconciliation, never blind retry. Transient backoff/jitter; authentication/certificate interaction stops unattended retries. Battery preferences never defer urgent renewal.

User requests local build/install and their own physical acceptance. No push/tag/release until explicit approval after testing. Existing library/session/Keychain data retain formats; checkpoint before replacing app. English localization catalog and exact coverage report; unreviewed target languages fall back to English. No invented translations or measurements.

Validation: deterministic fake clock/device/account/retry/lease tests, capability acknowledgement regressions, Rust/auth/Swift suites, release app/DMG/signatures. Physical multi-day renewal,2phones,SMS,sleep/network/unplug,VoiceOver/RTL/Instruments and production credentials remain separate manual gates. No live tests inferred from CI.

Production distribution requires securely provisioned DeveloperID private key/notarytool profile/clean-Mac Gatekeeper checks. Automatic updater additionally needs authenticated signed feed/artifacts and controlled signing keys; never trust same-channel SHA alone. macOS26/arm64 remains supported target absent actual lower-OS evidence.
