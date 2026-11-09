# Slip 2.9.2 — Automatic Capability Review Acceptance

Slip 2.9.2 removes interactive interruptions during app installation and refresh when apps have capability differences from the original IPA.

## Changes

- **Automatic Capability Acceptance:** Removed the blocking modal review dialog during app installation and refresh. Capability limitations (such as missing push notifications or iCloud capabilities when signing with personal Apple developer profiles) are now automatically accepted so the installation proceeds smoothly without requiring manual confirmation.
- **Background Refresh Continuity:** The background auto-refresh worker now automatically acknowledges capability differences, preventing apps from being paused under "Needs attention" due to profile capability changes.
