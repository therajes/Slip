# Slip 2.3 reliability improvements

This release keeps the approved interface, icon and Droppy 1.7 backdrop. It
improves day-to-day installation and renewal without changing the Rust signing
engine, Apple authentication provider choice or certificate-revocation policy.

## IPA imports and downloads

An IPA replacement is inspected before committing it to the workspace. Invalid
archives and stale inspection results preserve the current app, icon and all
customizations. Successful inspection commits first; icon extraction completes
separately without delaying readiness.

URL downloads use a disk-backed URLSession download task with byte counts,
percentage when the size is known, transfer speed and cancellation. Cancellation
also stops retry waits. New imports are staged under unique filenames; cancelled,
invalid or superseded downloads are removed. A cancelled/failed replacement does
not clear the current workspace.

Only transient transport failures and HTTP 429/500/502/503/504 retry, up to three
attempts with bounded delay. Permanent access failures and HTML responses receive
actionable messages. Signed query-string links work; embedded URL passwords and
HTTPS-to-HTTP redirects are rejected. Download URLs are not written to Activity.

## Installation and renewal

A kernel file lease serializes installation and refresh across the app and its
worker, including requests within the same process. It stays held for the actual
operation lifetime. A large installation is no longer considered stale after
twenty minutes, and process exit releases the lease automatically.

Schedule mutations use a separate short file lease and an atomic read/modify/write
transaction. Worker results merge only the affected, unchanged recipe. They
preserve pauses, do not overwrite replacement recipes and do not resurrect deleted
schedules. Unreadable schedule data is preserved and reported in the interface.

Foreground Refresh now and Refresh all use the same interactive protocol flow as
installation. They can present Apple's verification/certificate prompts, retain
saved signing options and address the original iPhone. The queue stops after a
failure or cancellation rather than repeatedly authenticating the remaining apps.
Paused recipes can be renewed manually; Refresh all respects pauses.

The unattended worker cancels challenges it cannot answer and keeps their outcome
as Needs attention, even when the cancelled core subsequently reports an error.
It never revokes a certificate automatically. Background eligibility checks run
every fifteen minutes; items needing user action stay out of unattended
authentication retries until the user refreshes them or re-enables their schedule.
Transient connection failures remain eligible for bounded future checks. Checks run
without contacting the core unless a recipe is due. Updating
the LaunchAgent holds the operation lease so an active install is not terminated.
Registration is checked before reporting that background renewal is ready.

Auto Refresh shows time remaining, urgent expiry and expired state. A missing IPA
offers a replacement-file action. This opens the validated app in Install with
saved signing choices for review; optional extensions start disabled and a notice
explains that choice. Signing is still an explicit user action.

Quitting during work offers to keep Slip open or stop/wait before quitting. The
app waits for its running operation to finish cleanup before exiting.

## Validation

The Swift suite has 45 passing tests, including 19 new download and reliability
checks. New tests use synthetic credentials, fixture core processes and loopback
HTTP servers; no Apple credentials or developer resources are used. They cover
downloads, retry/cancellation, transactional imports, operation leases, schedule
merging, expiry boundaries, invalid typed values and verification prompt handling.

The deployment target remains macOS 26, built using public Xcode 27.2 / SDK 27.2.
Real Apple sign-in, certificate issuance/revocation and device reinstallation are
separate from these local regression checks. The packaged core, helper and icon
resources are preserved from the installed 2.2.0 app. Build and live-interface
verification records are stored under ignored `native/build/reliability-2.3`.
