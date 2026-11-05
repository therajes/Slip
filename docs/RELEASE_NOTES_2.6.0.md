# Slip 2.6.0 — Renewal and recovery

Slip 2.6 makes renewal deadlines clearer and interrupted operations easier to recover. Requires an Apple-silicon Mac with macOS 26 or newer.

## What changed

- **Signed-profile deadlines:** the core reads expiry from signed provisioning profiles and uses the earliest available deadline across the app and its extensions. Renewal is scheduled one day earlier. Older schedules and unavailable profile dates remain explicitly estimated until a successful renewal provides a profile date.
- **App ID planner:** the current workspace and ready queued apps are grouped by selected account. Slip compares their signing identifiers with that account's Apple registrations, shows new versus reused IDs, and identifies optional extension costs. Registration checks show their timestamp. The plan is an estimate, not a reservation or a guarantee of Apple's quota.
- **Download recovery:** Pause appears for byte-range transfers with a strong ETag and known size. Resume checks the final URL, ETag and size before using URLSession resume data. Changed or unverifiable files require a fresh transfer. Paused transfers last for the current app session; servers may refuse resume.
- **Queue controls:** pause after the current app completes, cancel the current app, or stop the queue. Interrupted signing and installation restart after review; they do not offer byte-level resume. Failures halt the queue.
- **Wake recovery:** due renewals are checked after the Mac wakes. Interactive authentication failures remain excluded from unattended retries. Quiet renewal notifications are opt-in in Auto Refresh and off by default; macOS notification permissions still apply.
- **Diagnostics:** Activity distinguishes unreachable providers, incompatible metadata, Apple authentication, pairing and transfer errors. Preview a support report with URL, account-address, device-identifier, credential-pattern and local-path redaction before copying it. Review remaining names and free-form messages before sharing.
- **Release refresh:** updated layered icon materials retain Slip's approved symbol; new native screenshots, a refreshed repository overview and a newly built versioned DMG accompany this release.

## Data and rollback

The updater preserves the library, renewal schedules, account/session files and Keychain items. Existing dates are not rewritten simply by opening 2.6. Private checkpoints and the previous application are retained locally under `native/build/update-2.6`, outside version control. Source IPAs are not moved or deleted.

## Validation

- Rust library tests: 35 passed.
- Swift regression tests: 75 passed, including the five-test renewal/recovery suite.
- Real loopback HTTP tests cover pause/resume with exact byte comparison and changed-ETag rejection, redirects, retries, cancellation and invalid archives.
- Backward-compatible schedule decoding, wake eligibility, report redaction, diagnostic classification and account/team-scoped reuse are covered without modifying real Apple resources.
- Installer background aliases now use canonical paths, avoiding broken references when macOS maps `/var` to `/private/var`.
- Optimized native build and bundled core/app signatures verified. The installed app and core match the build; saved data was unchanged during replacement.
- Native UI reviewed for renewal estimates, notification preference, App ID planner, Activity, support preview and the rendered drag-to-Applications installer. Screenshots are from 2.6; older images remain labeled in the gallery.

Live Apple sign-in, signing and installation, an actual sleep/wake renewal, and notification delivery were not exercised during this release. The real profile-decoding path requires a successful signing run. Developer ID distribution signing and Apple notarization are not configured; GitHub builds are ad-hoc signed.
