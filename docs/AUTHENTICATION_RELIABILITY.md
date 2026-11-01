# Authentication reliability — Slip 1.3.0

## User-visible flow

Apple's verification code appears in the Add an account form, immediately below
the password. It accepts a pasted six-digit code, receives native keyboard focus,
and supports Return, resend, method selection, and cancellation. The verification
step remains visible while Apple completes account authentication and issues the
developer session. A failed attempt retains the form and identifies the failed
step; entering a code is not displayed as completed sign-in.

The form has a single explicit authentication state. Duplicate verification,
resend, and method requests are blocked until the current response arrives.
Rejected codes reopen the same challenge. Transient verification transport errors
do not automatically replay a potentially accepted code. Install/resource prompts
remain separate and have the same submission guards. Motion respects Reduce Motion
and the existing Slip appearance preference.

## Backend ownership and recovery

`src-tauri/src/authentication.rs` owns lifecycle events, error classification, safe
retry policy, and developer-session validation. The existing account context and
authentication provider remain attached throughout verification and subsequent
developer access checks. Safe token/team operations retry transport or temporary
service failures at most three times with bounded delay. Credential rejection,
verification rejection, rate limits, account restrictions, and mutations do not
use that automatic retry policy. Network clients have connection/read/overall
deadlines; they do not hold a request open indefinitely.

`src-tauri/src/session_store.rs` stores developer tokens and identity secrets in
macOS Keychain under `com.slip.authentication.developer-session`. Its atomic,
mode-0600 `dev_session.json` contains account/provider metadata and a Keychain
reference, not the token. The parent storage folder is mode 0700. A token cannot
be reused for a different account or provider. Legacy plaintext caches have no
reliable provider binding, so they are invalidated on access and require one fresh
sign-in. Removing a saved session deletes its reference and Keychain item.
Each secure save stages a new Keychain reference before replacing metadata. A
failed metadata commit preserves the previous session, and successful provider
changes remove the old Keychain secret. A persistence failure is shown as a warning.
Signing keys and anisette state remain in the low-level library's local storage;
Unix storage directories are private (0700), and files are atomically written with
owner-only permissions (0600). They are not represented as Keychain-backed keys.

Anisette state has a separate directory per provider. This Mac mode stops if macOS
does not supply authentication data; it never silently changes to a remote service.
Remote compatibility requires a chosen HTTPS endpoint, or HTTP on literal
loopback addresses (`localhost`, `127.0.0.1`, `::1`) for a service on this Mac. Slip neither invents a
default public endpoint nor switches to backup public services. Existing saved
preferences remain, while new preferences default to This Mac. Automatic refresh
uses the same explicit provider choice.

Remote GrandSlam sign-in uses the selected provider's bounded, validated client
description and user agent rather than a hard-coded Android identity. For developer
requests, the existing Xcode application component is retained while the provider's
hardware and OS identity stay intact; Slip does not substitute the physical Mac's
identity for a remote provider. This developer-header compatibility choice remains
subject to live Apple validation. Redirects cannot silently select another service.

Swift's core client drains stdout in order and drains stderr without retaining
private third-party response data. It waits for EOF and process termination before
delivering terminal success/error, then releases the operation slot before allowing
an immediate retry. A failed exit, incomplete response, or cancelled operation
cannot be reported as successful sign-in. The default core log records only stable
error categories, not raw Apple responses, tokens, exception details, or passwords.

## Independence and free-account boundary

This is a Slip-owned coordinator and secure session layer, not a replacement for
Apple's servers or all third-party libraries. Low-level isideload authentication,
code-signing, and idevice communication code remains in use and retains its
licenses. A custom engine cannot guarantee authentication acceptance or service
availability.

The current Mac's AOSKit check fails without submitting credentials. A working
local-only authentication path has **not** been demonstrated on this macOS version.
The supported-tooling alternative is an Xcode Personal Team provisioning/signing
adapter, which is documented as a future integration rather than exposed as a
working feature. See [local authentication compatibility](LOCAL_AUTHENTICATION_COMPATIBILITY.md)
for evidence, reproduction commands, and the required signing-adapter work.

A free Apple Personal Team remains sufficient for personal development signing.
Apple documents three installed apps per device, ten App IDs, three devices, and
seven-day profiles. Renewal still requires Apple services and a reachable device.
See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account).

## Validation boundaries

Recovery tests simulate transport interruption, rate limiting, persistent outage,
and provider mismatch using synthetic inputs. Session tests use an in-memory vault,
and the native protocol fixtures are temporary local scripts. The UI layout render
uses an isolated fake account. No test accesses saved account secrets or submits a
real Apple password or verification code. Successful live sign-in, Personal Team
provisioning, signing, and iPhone installation require a separate real-account check.

The pre-update installed application is retained in
`native/build/Slip-1.2.1-before-authentication-repair.zip`.

Run the packaged negative-path protocol checks without contacting Apple:

```sh
python3 native/Tests/validate_authentication_protocol.py native/build/Slip.app
```
