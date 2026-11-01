# Local Apple authentication compatibility

Checked on 2026-10-27 on this Mac running macOS 27.0, build `26A5378n`.

Slip's bundled `slip-anisette` helper requests a matched machine ID and one-time
password from the system AOSKit framework. It does not submit an Apple Account
password or verification code. The `--check` command returns availability and a
stable capability code only; it never returns authentication tokens. On this
installation the system logged `AOSKit ... Info request failed: -45070`, and the
helper returned `available: false`, `code: "headers_unavailable"`. There is no
working independent local authentication path demonstrated on this Mac yet.

## What the evidence establishes

- [AltStore's native implementation](https://github.com/altstoreio/AltStore/blob/marketplace/AltServer/Anisette%20Data/AnisetteDataManager.swift)
  uses the same `AOSUtilities` production request. Its alternatives include XPC
  and a historical Mail plug-in, which have OS/security limitations.
- [AltStore PR 1770](https://github.com/altstoreio/AltStore/pull/1770) reports that
  recent macOS versions gate the underlying service behind private entitlements.
  It proposes a Linux guest running ADI as a workaround. This is an upstream
  diagnosis, consistent with this Mac's empty response; the check alone does not
  establish the exact reason macOS refused this particular request.
- [The anisette-v3 maintainer's October compatibility discussion](https://github.com/Dadoum/anisette-v3-server/issues/61)
  documents Apple rejecting Android-derived authentication identities. Packaging
  that implementation in a local VM would remove a public service dependency,
  but does not establish that Apple accepts the resulting identity today.
- [The community macOS 27 fix's technical description](https://github.com/kimziro/altserver-macos27-anisette-fix/blob/main/TECHNICAL_DETAILS.md)
  describes a remote V3 service behind its helper. Its [current project description](https://github.com/kimziro/altserver-macos27-anisette-fix)
  also identifies an external service dependency. The presence of a locally
  bundled helper is therefore not proof of local-only authentication.

Slip must report this boundary honestly. A custom backend can own the sign-in
state machine, session storage, retries, signing, and installation, but Apple
still controls authentication and issuance of developer sessions and provisioning
profiles. A free Personal Team does not grant an application Apple's private
system entitlements. No public-service fallback should occur without the user's
explicit provider choice.

## Helper contract and failure handling

Successful availability output is `{"available":true,"code":"ready"}`. Failure
output has `available:false`, a stable `code`, and a fixed explanatory `message`.
Known codes are `framework_unavailable`, `api_unavailable`,
`headers_unavailable`, `headers_incomplete`, `headers_conflict`,
`identity_unavailable`, `api_exception`, and `invalid_arguments`.

The Rust caller uses only known codes to select fixed messages; it never forwards
arbitrary helper text or exception details. It retains diagnostic output from
nonzero exits, caps stdout at 64 KiB, drains it while the helper runs, enforces a
15-second deadline, and terminates/reaps the helper on failure or cancellation.
Both layers reject incomplete/conflicting authentication data. The Objective-C
boundary verifies method signatures before invoking the private API.

## Paths that remain worth validating

1. Recheck the system helper after macOS changes. `--check` is sufficient for
   availability and does not require user credentials.
2. Investigate an Apple-supported developer-session workflow that the user
   completes through Xcode. Any integration must use an intentional supported
   export/import boundary; Slip must not extract Xcode's saved account secrets.
3. If the user wants remote compatibility, require an explicit trusted provider
   and preserve its matching client identity. A user-controlled provider on a
   compatible Mac would still be another machine, and needs its own end-to-end
   validation. It is not implemented by this helper repair.

Disabling SIP or AMFI, patching system software, impersonating an Apple-signed
application to obtain restricted privileges, or silently swapping providers are
not part of the implementation.

## Xcode Personal Team alternative

Read-only tooling checks found a selected full Xcode 27.0 beta installation
(`27A5228h`) at `/Applications/Xcode-beta.app/Contents/Developer`, including the
iPhoneOS 27 SDK. No Xcode accounts, passwords, session tokens, or private keys
were inspected. The installed `xcodebuild -help` documents automatic provisioning
through `-allowProvisioningUpdates` and `-allowProvisioningDeviceRegistration`
after the user adds an account in Xcode Settings.

[Apple documents free Personal Teams](https://developer.apple.com/help/account/basics/about-your-developer-account)
and [using Xcode-created identities with external build systems](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates).
This makes Xcode-mediated provisioning a plausible service-independent mode to
prototype: the user signs in and completes 2FA within Xcode, Slip builds an
auto-signed temporary project for the selected team/device and requested bundle
IDs, and consumes the profiles from its own build products. A separate signing
adapter could invoke `/usr/bin/codesign` using the authorized Keychain identity,
without exporting its private key. Slip's existing Rust signer currently expects
private key bytes, so this cannot be substituted as a provider-only change.

This route still needs an end-to-end proof on the user's free account. Apple
documents personal development signing; it does not promise that every third-party
IPA can be adapted. Retained extensions require profiles and compatible
entitlements, and unsupported capabilities can prevent an app from working.
Consume the development build product rather than requiring a distribution
export, because [Personal Team export limitations apply](https://developer.apple.com/library/archive/qa/qa1915/).
Seven-day expiry and app/device/App ID limits remain. Background renewal also
depends on a usable Xcode session, accessible signing identity, and a reachable
device; reauthentication can require user interaction.

## Reproducible checks

For an explicitly selected remote provider, the V3 metadata contract is
`GET /v3/client_info` with snake-case `client_info` and `user_agent` strings.
This is implemented in the [upstream service source](https://github.com/Dadoum/anisette-v3-server/blob/main/source/app.d).
[AltSign PR 61](https://github.com/rileytestut/AltSign/pull/61) documents why a
hard-coded Android/Mac identity can disagree with the provider and result in Apple
rejecting authentication. Slip must retain the selected service's validated
identity throughout the operation; remote-generated data does not become local
Mac data by changing its descriptor. Metadata-only loopback fixtures verify that
the selected endpoint is used, that its identity is cached per provider, and that
redirects and excessive response bodies are rejected. They do not establish that
Apple accepts a particular remote provider or account.

```sh
xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=15.0 -framework Foundation \
  native/Tests/AnisetteHelperTests.m -o native/build/anisette-helper-tests
native/build/anisette-helper-tests
cargo test --manifest-path src-tauri/vendor/isideload/Cargo.toml --lib anisette::local_macos::tests
cargo test --manifest-path src-tauri/vendor/isideload/Cargo.toml --no-default-features \
  --features fs-storage,install,tokio-mt --test remote_client_info
```

The helper fixtures are synthetic; the Rust checks cover unsafe/missing fields,
secret-free diagnostics, nonzero-exit status, oversized stdout, and deadlines.
These checks do not demonstrate a live Apple Account sign-in or device install.
