# Slip 2.9 engineering

Baseline: released v2.8.0; SMS is owner-confirmed working. Preserve authentication and signed outcome checks.

- Existing library version 1 remains readable; deployment metadata is additive. Restored queues always require review.
- MainActor owns view-facing publications. IO repositories are actors; immutable snapshots cross isolation boundaries.
- Lock order: foreground coordinator → operation kernel lease → repository-specific write lease. Never await UI authentication while holding a repository write lock. One core signing stream; sequential targets only.
- Identity: exact UDID + source SHA256 + account/team + effective bundle ID + options digest. New source or selections invalidate approval.
- IPC adds version/request/operation/sequence fields with legacy decoding. Cancellation is distinct from failure; uncertain transfer requires inventory reconciliation.
- Catalog is user opt-in; source claims are unverified, cache freshness visible, download/inspection precedes review.
- Backups contain allowlisted nonsecret metadata, optional bounded IPA copies, checksums and a version manifest. Import previews conflicts, resets approvals and schedules no unattended signing.
- Work packages: deployment and targets; catalog/provenance; facade/protocol extraction; backup and integration.
- Validation: existing Rust core/auth + Swift suites, new deterministic domain fixtures, app build and DMG. Real multidevice, live Apple, Instruments and production notarization are separate evidence; never inferred from mocks.

Completed local gates:48 core,20 authentication,113 Swift tests; native release app and verified DMG. Archive format and rollback details are in MIGRATION_2.9.0.md. New physical tests and Instruments are not performed.
