# Slip 2.8.0 — Signing Intelligence, Trust & Reliability

Slip 2.8 builds on the existing Install, Library, Accounts and Refresh Guard workspaces. It preserves the authentication stack, reviewed sequential queue, operation leases and 2.7 storage formats.

## Signing and outcome evidence

Installation Readiness displays versioned checks with severity, source, stage, observed/expected values and suggested resolutions. Archive inspection reports entitlement and provisioning evidence separately: a source embedded profile is not the profile Apple will issue. Unknown data cannot establish signing compatibility. Expand each row for evidence and technical keys. Existing customization and extension controls remain in place.

Before transfer, checks inspect the signed bundle against the generated profile. Source-versus-signed capability limitations require review. App ID projections remain informational until Apple responds; no preflight portal mutation grants capabilities or bypasses free-account limits.

A successful core exit or completed transfer cannot alone establish installation success. Slip checks the effective bundle ID against inventory on the intended iPhone. When inventory is unavailable, the outcome remains Verification Pending. Pending work can be reconciled by checking inventory instead of blindly repeating the install. Saved and observed installed versions remain distinct; a matching bundle alone does not prove a particular update version or receipt.

## Recovery, privacy and local input

Typed diagnostic codes carry phase, retryability and safe recovery actions. Older core messages retain a compatibility fallback. Support reports have an allowlisted diagnostic representation for review; credentials and private context do not belong in exported reports.

IPA inspection rejects traversal, duplicate/case-colliding paths, symlinks and special files. Documented safety caps are 200,000 entries, 8 GiB per expanded entry, 32 GiB total expansion, 32 MiB aggregate path metadata, and a 1000:1 compression cap for entries larger than 16 MiB. Plist metadata is limited to 8 MiB and binary inspection to 256 MiB. These are validation limits, not silent truncation. Imported binaries are never executed as host programs. Original IPA files are preserved.

Native UserNotifications replace notification AppleScript. Permission is requested from interactive UI, and notification actions return to the foreground workflow rather than assuming headless authentication can complete. Banners exclude account and device identity.

## Preservation and validation limits

The owner personally confirmed live SMS-only Apple Account sign-in on Slip 2.7 works. This release preserves trusted-number selection, challenge routing, explicit resend, six-digit parsing and wording. Automated coverage does not constitute a new live 2.8 sign-in test.

Library/workspace and renewal formats remain compatible; Keychain/session references are retained. A separate operation journal is used for verification recovery. No destructive migration, credential export, certificate revocation or pairing reset is required.

The lead's end-of-task report records the actual command results. This document does not assert tests, build, DMG packaging, live signing, iPhone transfer, notification delivery, Gatekeeper or production notarization passed. See [manual checks](MANUAL_TEST_MATRIX_2.8.0.md).

Production Developer ID signing, Hardened Runtime, `notarytool`, stapling and Gatekeeper assessment are opt-in. They require a securely provisioned identity and notary keychain profile. Default local builds continue without those credentials. No release tag or GitHub Release is created by this implementation task.

Potential follow-up work includes richer Apple resource freshness APIs, reliable installed-version/receipt evidence across iOS versions, and broader architecture/profile fixtures. Preliminary checks remain evidence, not a promise of successful signing or runtime behavior.
