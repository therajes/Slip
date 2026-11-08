# Slip 2.8.0 — Signing Intelligence, Trust & Reliability

Slip 2.8 makes signing decisions and installation outcomes clearer while preserving the existing native workspace, library, reviewed queue and working Apple Account authentication.

## What's new

- **Installation Readiness:** grouped checks explain source entitlements, provisioning evidence, affected components and safe next steps. Compare observed and permitted capabilities side by side. Preliminary checks remain distinct from the authoritative issued-profile check before transfer, and functionality limitations require explicit review.
- **Verified installations and updates:** Slip checks the intended iPhone and compares available version/build evidence. Uncertain outcomes remain Verification Pending. Private operation journals allow recovery to verify device state without blindly repeating an installation.
- **Safer IPA inspection:** validate thin/fat32/fat64 Mach-O slices and component architectures; reject unsafe ZIP paths, duplicate/case-colliding entries, symlinks and special files. Parsing and inspection tools have size and time budgets. Original IPAs remain unchanged.
- **Actionable recovery:** stable diagnostic categories, contextual recovery actions and previewable, allowlist-based support reports keep private context out of exports.
- **Device Health and App ID planning:** inspect masked device identity, transport, OS and last-seen evidence; retest connectivity and review account/team provenance and resource freshness. Unknown trust or Developer Mode state stays clearly labeled.
- **Native notifications:** GUI-owned authorization and foreground actions replace AppleScript banners. Notifications avoid private account/device details.
- **Download protections:** reject private/reserved and alternate numeric HTTPS endpoints, check DNS results and redirects, and preserve existing explicit local HTTP IPA import compatibility.

## Your existing data and sign-in

Existing libraries, managed IPA references, renewal schedules, account sessions and Keychain references retain their formats. Recovery records use separate private sidecars; no destructive migration is required.

SMS sign-in preserves trusted-number selection, challenge routing, explicit resend, six-digit parsing and wording. The owner confirmed the release's functionality is working and authorized publication. This is owner-reported live validation; automated agents did not collect personal credentials or perform those live account/device tests.

## Validation

Local validation passed **48 core Rust tests, 20 vendored authentication tests and 96 Swift tests**, plus the native release build and verified DMG packaging. The GitHub tag workflow independently reruns tests, builds the app and DMG, verifies packaging and generates the published SHA-256 checksum.

## Download and signing

Requires Apple silicon and macOS 26 or newer. Download `Slip-2.8.0.dmg` and drag Slip to Applications. `SHA256SUMS.txt` accompanies the installer.

Default GitHub builds are **ad-hoc signed and not Apple-notarized**. macOS may require explicit approval to open the downloaded app, and replacing a locally development-signed build can prompt for renewed Keychain access. Production Developer ID signing, Hardened Runtime, notarization and stapling are supported when securely provisioned credentials are supplied; production notarization is not claimed for the default artifact.

Apple's signing limits still apply. Source profiles do not guarantee the capabilities of a newly issued profile. Missing reliable inventory evidence remains pending; architecture compatibility does not guarantee runtime functionality. DNS prechecks do not pin a connection against a malicious rebinding server. See the [manual validation matrix](MANUAL_TEST_MATRIX_2.8.0.md) and [implementation report](IMPLEMENTATION_REPORT_2.8.0.md) for scope and technical details.
