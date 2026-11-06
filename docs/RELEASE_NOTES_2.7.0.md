# Slip 2.7.0 — App management and SMS sign-in

Slip 2.7 adds update subscriptions, cached library artwork, version history, reusable customization presets and optional managed IPA storage. It also fixes SMS verification routing for Apple Accounts without trusted Apple devices.

## SMS verification fix

Apple's explicit SMS authentication challenge takes precedence over a generic 409 status. Slip retrieves actual trusted phone-number IDs instead of guessing ID 1. One available number receives a single request; multiple numbers are presented for selection. Selecting an already active SMS destination preserves the existing challenge. Resend remains an explicit action.

Sign-in and installation prompts use SMS-specific wording and do not offer trusted Apple devices for an SMS-only challenge. Ambiguous pasted messages and overlong codes are rejected instead of silently submitting their first six digits. Spaces and hyphens in a six-digit code remain supported. Apple rejection and transport errors retain the current challenge.

These paths have regression coverage, but this release was not tested with a live SMS-only Apple Account. Retry sign-in in the updated app using only the code's six digits; do not share passwords or verification codes in reports.

## App Library

- **Updates:** choose Updates beside an app and enter its developer's GitHub repository or HTTPS AltStore source URL. Checks are manual. Subscriptions, checked results and timestamps persist per workspace. GitHub draft/prerelease entries are excluded, and multiple IPA assets require a choice.
- **Version and compatibility:** inspect release notes, available versions and developer-provided iOS requirements. Saved IPA and installed versions are distinct; an installed version is shown only when a device-scoped inventory matches. Missing compatibility and unverified installed versions are explicitly labeled. AltStore's developer-supplied release order is retained.
- **Prepare Update:** download and inspect the IPA, require the original app's bundle ID, restore saved customization choices, and invalidate any old queue approval. Signing and installation remain separate review actions. Previous workspaces survive failed downloads or mismatched IPAs.
- **Artwork:** library rows display real IPA artwork through the bounded disk and thumbnail caches, with an initials fallback. Saved file stamps keep previously cached artwork available when an original IPA is missing.
- **Manage App:** save named presets, apply them for review, and inspect version history. Presets include preparation choices, excluding account/device credentials. Custom icon references still require the referenced image to exist. History begins with saves and confirmed installs in 2.7; no past installations are invented.
- **Managed storage:** optionally copy an IPA into Slip's storage. The copy is checked against the original with SHA-256 before workspace, queue and renewal references change. Originals are preserved.
- **Storage cleanup:** preview unreferenced managed files, then confirm moving them to Trash. Saved workspace, queue and renewal references are protected; schedules are checked again under an operation lease. Cleanup excludes symlinks and files outside the dedicated managed directory.

Feed responses are limited to 4 MB, use HTTPS without embedded credentials, and reject insecure redirects. Feed metadata is supplied by developers; compatibility declarations do not replace IPA inspection. This release does not automatically install app updates or discover a developer's source without a user-provided URL.

The source parser follows the documented [AltStore source format](https://faq.altstore.io/developers/make-a-source).

## Preservation and validation

- Existing libraries, schedules and account/session files are unchanged during replacement. Keychain items are not exported or rewritten.
- The prior 2.6 app and a private data checkpoint are retained locally under `native/build/update-2.7`, outside version control.
- 85 Swift tests, 35 core Rust tests and 20 authentication-library tests pass locally. CI runs all three suites before publishing.
- Coverage includes SMS routing and destination selection, native code-entry state, exact feed bundle matching, release ordering, duplicate releases, URL policy, version comparison, preset privacy, history persistence, verified copies, reference protection and symlink exclusion.
- The native optimized build, bundled core signature and application signature verify. The new library, update and management panels were reviewed in the installed application; screenshots show actual native UI.
- Live Apple SMS sign-in, signing an update and transferring it to an iPhone remain unverified. No new Instruments comparison was performed; this release makes no measured performance claim.

Requires Apple silicon and macOS 26 or newer. GitHub release builds are ad-hoc signed. Developer ID distribution signing and Apple notarization are not configured.
