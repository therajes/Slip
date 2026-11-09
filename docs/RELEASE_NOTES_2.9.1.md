# Slip 2.9.1 — Capability Review Fix

Slip 2.9.1 addresses an issue during app installation and refresh where accepting capability changes was misinterpreted by the signing core as a cancellation.

## Bug Fixes

- **Capability Review Acknowledgement:** Fixed a JSON field serialization mismatch (`acknowledgeCapabilities` vs `acknowledge_capabilities`) between the Swift UI and the Rust core. When an app has capability differences from the original IPA (e.g. push notifications or iCloud unavailable under a free developer profile) and the user chooses "Accept Limitations & Continue", the installation now properly proceeds instead of aborting with "The operation was canceled".
- **Protocol Flexibility:** Added Serde field aliasing in the core so both camelCase and snake_case capability prompt responses are accepted.
- **Build Toolchain Resolution:** Ensured native build scripts consistently select the active Xcode Swift toolchain.

## Verification & Compatibility

- Preserves all 2.9.0 features including source catalogs, durable deployment targets, portable backups, and working SMS authentication.
- All core Rust tests, Apple authentication regression tests, and native Swift tests pass.
