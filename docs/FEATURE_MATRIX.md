# Slip feature matrix

This matrix is the feature overview for Slip 2.6. Slip is designed only for personal iPhones running stock iOS.

## Shipped

| Area | Capability | Notes |
| --- | --- | --- |
| IPA input | Drag and drop, Finder, HTTPS URL, `slip://` | URL imports retry transient failures. Supported transfers can pause and resume after URL, ETag and length validation. |
| Inspection | Identity, artwork, version, build, minimum iOS, size, main executable, encryption | Artwork follows the IPA’s declared icon metadata, with safe fallbacks for unusual names and legacy Apple CgBI PNGs; encrypted executables are blocked before signing. |
| Extensions | Inspect, keep individually, remove individually, remove all | The account-aware planner shows new and reusable IDs, optional extension costs and the last registration check. |
| Identity | App name, bundle ID, icon | Extension bundle IDs follow the changed main bundle ID where safe. |
| Compatibility | Minimum iOS override, remove `UISupportedDevices` | Overrides cannot make an app compatible when its binary or frameworks require newer APIs. |
| Documents | Enable Files/Finder document sharing | Adds the standard file-sharing plist flags. |
| Metadata | Typed String, Boolean, Integer, and Real Info.plist overrides | Limited to top-level values so changes remain reviewable. |
| Memory | Increased-memory entitlement request | Apple and the selected provisioning profile remain the final authority. |
| Export | Save prepared IPA without installation | Useful for inspection, archiving, or a separate signing workflow. |
| Accounts | Apple Account profiles, local avatars, 2FA, certificate management | Password storage is opt-in and uses macOS Keychain; verified names come from Apple authentication while custom photos stay local. |
| Installation | Direct stream, phase progress, bounded retries | A reconnect gets a fresh device session rather than reusing a broken channel. |
| Devices | USB and paired local-network discovery, exact model preview | Slip resolves the trusted hardware identifier and renders model-aware Dynamic Island/notch and display proportions. USB is preferred for large transfers. |
| Refresh | Saved recipes, Refresh All, launch-at-login guard | Due time is one day before signed-profile expiry; fallback dates are labeled estimated. Wake recovery and optional quiet notifications are included. |
| Inventory | Native app icons, select, copy bundle IDs, refresh managed apps, uninstall user apps | Icons are read from the paired iPhone through SpringBoard; uninstall requires confirmation, reports partial failures, and removes matching refresh recipes so removed apps stay removed. |
| Diagnostics | Activity timeline, actionable recovery, previewable redacted support reports | Privacy mode hides Apple IDs, device IDs, and the user home path. |
| Appearance | Native Liquid Glass, adaptive light/dark glass icon, dimensional symbols, motion control | Automatic icon mode follows the Mac appearance; Reduce Motion always takes priority. |
| Preflight | Bundle ID, iOS version, encryption, custom icon, typed plist, duplicate/protected-key validation | Blocking issues disable installation and explain the correction before Apple signing starts. |
| Performance | Raw transfer of unchanged compressed IPA entries | A 196 MB test IPA prepared in 1.15 seconds versus 4.42 seconds in 1.0 on the same Mac. |

## Deliberately constrained

| Request | iOS 27 reality | Slip policy |
| --- | --- | --- |
| Permanent free signing | The seven-day profile lifetime is enforced by Apple. | Slip refreshes through the Mac; it never claims to bypass expiry. |
| More than three free apps | The active-app limit is enforced by Apple services and iOS. | Slip shows App ID cost and makes extension removal easy. |
| Mac-free background refresh | Stock iOS does not allow a third-party Mac installer to silently renew other app signatures on its own. | Refresh Guard requires this Mac and a reachable paired iPhone. |
| JIT on iOS 27 | Public desktop sideloading JIT techniques do not support current iOS releases without additional Apple-granted capabilities or security-sensitive workflows. | No misleading JIT switch is shown on unsupported iOS. |
| Arbitrary entitlements | An entitlement must be permitted by the app ID and provisioning profile; adding text alone does not grant it. | Slip exposes only reviewed transformations and reports signing failures honestly. |
| Tweak/dylib injection | Safe injection requires architecture-aware Mach-O editing, dependency validation, compatible decrypted binaries, and extensive runtime testing. | Not shipped in 1.1; Slip will not bolt on an unverified injector that produces crash-prone IPAs. |
| No-sign/jailbreak modes | These target a different trust and security model. | Outside the stock-iPhone scope. |

## Explicitly out of scope

- Apple TV installation.
- Installing iOS apps on Apple-silicon Macs.
- Certificate resale, shared-account services, profile-lifetime bypasses, or Apple service abuse.
- Proprietary Sideloadly code, assets, branding, and paid-service replication.

## Next engineering priorities

1. App update feeds, version history, customization presets and managed IPA storage (planned for 2.7).
2. Provisioning-profile and entitlement diff preview before signing.
3. Richer structured device diagnostics beyond the current redacted Activity report.
4. Live-device validation of renewal after sleep/wake and notification delivery.
5. Reproducible release signing and notarization when a distribution Developer ID is available.
