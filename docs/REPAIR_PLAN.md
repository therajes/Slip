# Slip reliability repair

## Working prompt

Repair the native macOS Slip app and its bundled Rust core. Investigate Apple
Account sign-in, saved-session recovery, two-factor authentication, signing
certificate limits, App ID management, and IPA import/preparation/export. Fix
concrete defects found in these paths and provide actionable errors with reliable
cancellation and loading states. Let the selected account list its existing
development certificates and App IDs, and revoke or delete an explicitly selected
resource only after a destructive-action confirmation. Never revoke certificates
automatically. Preserve the existing native design and Keychain credential storage.

Validate the relevant regression tests, build and sign the native application,
check its bundled core and launch behavior, then replace `/Applications/Slip.app`.
Preserve a rollback copy of the installed application. Report exactly what passed
and which live Apple/device operations still need an account or connected iPhone;
do not claim that every possible bug has been eliminated.

## Plan

1. Trace the installed native application's account, prompt, process, and IPA
   flows. Split independent repairs between Apple/core, native UI, and IPA work.
2. Repair authentication and resource-management commands. Keep account selection,
   session cache, two-factor prompts, and certificate selection consistent.
3. Add native certificate and App ID lists with explicit refresh, clear states,
   confirmed removal, and useful errors. Repair prompt and subprocess lifecycle
   problems found during implementation.
4. Harden IPA validation, extraction, customization, and export. Reject unsupported
   signing inputs early and cover concrete archive regressions with tests.
5. Integrate the JSON protocol and native UI; run the Rust tests and native release
   build. Exercise local core commands and review the running application.
6. Back up the installed bundle, replace it with the verified build, and verify the
   installed signature, bundled core, and application launch.

## Validation boundaries

Local validation must not revoke real certificates or delete real App IDs.
Successful Apple sign-in, server-side resource changes, and device installation
require live account/device validation and must be reported separately from local
build and regression checks.

## Completed changes

- Shared Apple authentication and session recovery across installation and account
  management. Explicit sign-in checks the entered password before saving it;
  transport fallback avoids repeating credential and throttling failures.
- Certificate-limit selection and cancellation, certificate/App ID listing, and
  confirmed removal under Apple Accounts. Resource failures retain their actual
  recovery details. Management follows the first developer team used by Slip's
  existing signing flow; it does not yet provide a team selector.
- Trusted-device and SMS verification choices; native process cleanup, prompt
  state, incomplete-operation errors, and protection against stale IPA inspection.
- An editable authentication-service URL, shared by foreground and scheduled work.
- Archive path and extraction checks, isolated extraction directories, preservation
  of small assets/libraries, Mach-O encryption checks, extension customization,
  iPad icon metadata, and staged exports that preserve the original IPA.

## Validation results — 2026-10-25

- `cargo test --manifest-path src-tauri/Cargo.toml --no-default-features --lib`:
  11 tests passed, including authentication retry classification, actionable
  resource errors, archive validation, binary parsing, source preservation, and
  extraction isolation/asset preservation.
- `./native/build.sh`: Rust and Swift release build passed; bundled core and app
  signatures verified.
- 15 packaged-core checks passed using temporary IPA fixtures and invalid account
  requests, without sending Apple Account credentials or changing Apple resources.
- Four native protocol/lifecycle checks passed: verification-detail decoding,
  core-error delivery, stream completion/reuse, and cancellation/reuse.
- `/Applications/Slip.app` replaced. Installed executable and core hashes match
  the build; installed signature verifies; the installed executable launches and
  remains running. Device discovery returns the connected iPhone without errors.
- Previous application preserved at
  `/Users/rajeshbarik/Library/Application Support/Slip/Backups/Slip-20261025-220025.app`.
- Visual UI review is incomplete: the computer-use inspection helper crashed or
  timed out. Live Apple sign-in, certificate revocation, App ID deletion, and
  signing/installing a real IPA were not exercised.

Apple documents the consequences and restrictions of
[certificate revocation](https://developer.apple.com/help/account/certificates/revoke-a-certificate/)
and [App ID deletion](https://developer.apple.com/help/account/identifiers/delete-an-app-id/).
The new confirmation messages reflect those constraints; Apple may reject a
resource change even when it is visible in the list.
