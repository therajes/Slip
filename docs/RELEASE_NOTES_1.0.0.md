# Slip 1.0.0

The first public Slip release is a native, iPhone-only IPA workflow for macOS, with Liquid Glass on current systems and a system-material fallback on earlier supported macOS releases.

## Included

- IPA inspection, executable encryption diagnostics, extension/App ID planning, identity/icon changes, compatibility controls, typed plist overrides, and prepared IPA export.
- Apple Account and 2FA signing with opt-in macOS Keychain storage.
- Fast streamed USB installation, bounded reconnect retries, paired Wi-Fi discovery, and USB fallback.
- Refresh Guard approximately 24 hours before free-profile expiry, saved recipes, Refresh All, and installed-app inventory.
- Privacy-redacted copyable activity logs and direct HTTPS/`slip://` IPA import.
- A polished drag-to-Applications DMG and fully native SwiftUI interface.

## Important limits

Slip does not bypass Apple's seven-day free-profile lifetime or three-app limit. Automatic refresh still requires this Mac, opt-in saved credentials, and a reachable paired iPhone. JIT, arbitrary entitlement granting, unverified tweak injection, Apple TV, and Apple-silicon Mac targets are not claimed or included.

The application is development-signed for this build and is not notarized. If Gatekeeper quarantines the download, review the source and build locally. Only install IPAs you are authorized to use.
