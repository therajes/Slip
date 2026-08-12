# Slip 2.0.0 — Native reliability release

Slip 2.0.0 is a focused native macOS release for personal iPhones. It removes the dormant web/Tauri application, hardens the SwiftUI-to-Rust boundary, restores complete on-device app inventory, and makes background refresh coordination deterministic.

## Highlights

- Load user-installed iPhone apps with their SpringBoard artwork, search and select them once, copy bundle IDs, refresh Slip-managed apps, or uninstall with explicit confirmation.
- Inspect active Apple App IDs, Apple-reported quota and reset times, developer teams, and likely app/extension relationships from the Apple Accounts view.
- Keep an account identity without profile-picture uploads: verified names and generated initials stay compact at every window size.
- Refresh roughly 24 hours before free-profile expiry while preventing the launch agent and foreground app from using the device simultaneously.
- Reuse compressed IPA output on retries and continuously drain process output for faster, deadlock-free inventory and installation.

## Security and correctness

- Reject archive traversal, links, duplicate entries, oversized metadata and artwork, invalid identities, and unsafe Mach-O arithmetic before signing.
- Bound HTTPS downloads, icon payloads, process output, and temporary storage; sensitive local files use owner-only permissions.
- Keep Apple passwords in macOS Keychain, pass them through stdin only when needed, and zero the Rust request buffer after authentication.
- CI runs Rust formatting, tests, clippy, `cargo audit`, Swift warnings-as-errors, app/DMG builds, and checksum generation on an ARM64 macOS runner.

## Platform limits

Slip does not bypass Apple's three-app Personal Team limit or seven-day provisioning lifetime. Automatic refresh still needs this Mac, a reachable paired iPhone, the saved IPA, and the Keychain credential. The downloadable build is locally development-signed and is not Apple-notarized.
