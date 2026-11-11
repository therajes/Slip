# Slip 3.0.0 — Proactive Companion & Renewal Assurance

Release based on owner-confirmed local testing of Slip 3.0.0.

Downloads use prioritized native transfers and buffered streaming in the Rust backend. Compatible frontend dependencies were refreshed and deprecated native APIs replaced.

Refresh Guard uses shared eligibility and durable source/options review, pending-operation protection, explicit reasons and bounded retries. Interactive Apple decisions require opening Slip; a pending transfer is verified before retry. The optional native menu companion and Assurance center read the same schedules as the GUI/background worker. Preferences separate menu visibility, GUI login, background refresh and notifications/quiet hours. Onboarding permits offline IPA inspection without sign-in.

The existing SMS flow, preflight, verified/unknown outcomes, catalog, backups, reviewed queue and operation leases remain regression constraints. The 2.9.2 capability acknowledgement/auto-accept correction is preserved. Apple limits remain: Mac availability and a reachable iPhone are required; typical free profiles expire in seven days. No iPhone-only signing or permanent free signing is provided.

Local builds retain existing development/ad-hoc behavior. Production signing remains opt-in, requires securely provisioned identity/team/notary profile and is not claimed to have passed. Exact app/core/helper versions and signatures are checked; release evidence includes hashes and a Cargo lock inventory. Sparkle was evaluated but no unsigned/self-installing fallback ships. English is the source language; unavailable reviewed translations fall back honestly to English.

The implementation report records actual checks. New physical/multiday renewal, live Apple account/SMS, clean-machine Gatekeeper, Instruments and translation/accessibility review are not inferred from unit tests. See the user test checklist before approving release.
