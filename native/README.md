# Slip Native

Slip 2.5 improves targeted background autosaving, progress-update isolation,
cached artwork, lazy library rows and device-scoped inventory operations.
It updates the existing app while retaining saved data and renewal times.
See [the 2.5 release notes](../docs/RELEASE_NOTES_2.5.0.md).

Slip Native is the SwiftUI macOS application. It requires macOS 26 or newer and uses Apple's native Liquid Glass APIs. It bundles a separate Rust executable for Apple signing and iPhone communication.

Slip 2.4 adds an App Library, restored workspaces, multi-IPA imports and a reviewed,
sequential installation queue. See [usage and validation](../docs/APP_LIBRARY_2_4.md).

## Architecture

- SwiftUI/AppKit: windowing, navigation, drag and drop, file import, sheets, progress, accessibility.
- Security.framework: Apple Account passwords stored as generic-password items owned by `app.sideloom.native`.
- `sideloom-core`: internal newline-delimited JSON process protocol; handles IPA inspection/customization, Apple developer signing, usbmuxd/AFC, network devices, and Installation Proxy.
- Passwords are sent to the child core through an anonymous stdin pipe, never command-line arguments or environment variables.

## Build

Run `./build.sh`. The signed application is written to `native/build/Slip.app`.

Slip 2.3 adds cancellable IPA downloads, preserved workspaces on failed imports,
interactive manual renewal, expiry/recovery controls and cross-process operation
leases. Background renewal checks every fifteen minutes. See
[the reliability changes and validation boundaries](../docs/RELIABILITY_2_3.md).

The current release is built with public Xcode 27.2 and macOS SDK 27.2. The
deployment target remains macOS 26. Apple Accounts includes a live GitHub macOS
ADI server picker with preserved source order, explicit selection and a metadata
check before use. See [the server-directory behavior](../docs/LIVE_ANISETTE_DIRECTORY.md).

The native link step explicitly records the active macOS SDK from `xcrun` in
`LC_BUILD_VERSION`, independently of the macOS 26 deployment target. This avoids
SwiftPM's Xcode build path tagging the executable with SDK 15 when using Xcode 27.

Run `./create-dmg.sh build/Slip.app dist/Slip-2.5.0.dmg` to create the visual drag-to-Applications installer.

Packaging requires Python 3.10 or newer. The script installs its pinned, hash-checked Finder metadata tools into an isolated environment under `native/build/dmg-tools`. It writes the background and icon layout directly, then mounts the compressed image read-only to verify its contents, layout and app signature. Finder automation is not required.

GitHub builds and publishes version-tagged DMGs through [the release workflow](../docs/RELEASING.md). Automated builds use ad-hoc signing; Developer ID signing and Apple notarization require separate credentials and are not configured.


## Credits and licensing

This native application includes a modified adaptation of window, sidebar, toolbar, card, and theme interface code from **Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app** ([project website](https://getdroppycode.app)), Copyright (c) 2026 Jordy Spruit (Droppy). The adaptation is modified by Slip. Slip is not affiliated with, endorsed by, or made by Droppy or Jordy Spruit, and retains its own name, icon, and branding.

The combined native application incorporating that UI is available under GNU AGPL version 3 with the upstream additional terms in [LICENSE](LICENSE). The complete upstream [third-party notices](THIRD_PARTY_NOTICES.md) are preserved; listing an upstream component does not imply that Slip bundles it. Pre-existing MIT-licensed Slip/iLoader source and the original core retain their notices, including Copyright (c) 2025 nab138 in the unchanged [root MIT license](../LICENSE).

The corresponding source and build scripts for these adaptations are included in this repository. Distributors must provide corresponding source and notices for their builds under the applicable license terms.

The build bundles `Credits.rtf` for About Slip, the AGPL and additional terms as `License.txt`, the original MIT license as `OriginalLicense.txt`, and the preserved notices as `ThirdPartyNotices.txt` in the app's Resources directory.

## Workspace interface

The workspace ports Droppy Code's chrome measurements, sidebar rows, toolbar capsules,
quiet cards and 26 theme palettes to Slip's IPA, Apple Account and iPhone workflows.
Settings (Command-comma) includes theme, backdrop transparency, motion, haptics and
performance controls. Command-Shift-S toggles the movable, resizable floating navigation panel; Command-1 through
Command-6 opens each workspace page. Command-O opens an IPA from every page.

The device picker and sidebar use a phone outline with Wi-Fi on its display for a
network connection, and a connector outside the phone for USB. A model-aware phone
preview uses one settling spring when the connection changes. Trackpad haptics use
AppKit's native feedback performer and require supported hardware. Motion follows
Reduce Motion; surfaces follow Reduce Transparency and increased contrast.

Builds use release optimization, a clear AppKit window and one desktop blur for the window and lazy activity
rows. No repeating decorative animation runs while the workspace is idle.

Navigation floats over the full-width workspace without reserving a column. The window uses a continuous 26-point corner and the panel uses a continuous 22-point corner, each clipped once. On macOS 26+, the window backdrop copies the installed Droppy Code **1.7.0** implementation: SwiftUI `glassEffect(in:)`, a theme-aware scrim, a 12% theme wash, and a one-point rim. The newer downloaded source uses a heavier `NSVisualEffectView` instead; that obsolete path has been removed from Slip. The default slider value is Droppy's stock 50%; 0% retains Liquid Glass and removes only the scrim. Solid mode follows the light or dark theme. Later slider adjustments persist. Reduce Transparency, increased contrast and performance mode keep their solid alternatives. See [backdrop version parity](../docs/BACKDROP_VERSION_PARITY.md).

The complete window path also copies Droppy Code: a titled, clear AppKit window,
`DCDisplayCycleGuardedWindow`, the frame-driven `FrameHostingView` inside a plain
`NSView` container, and the real window's traffic lights. SwiftUI owns the rounded
content clip; no additional CALayer frame mask or SwiftUI scene background is
installed. The Objective-C display-cycle guard is retained in
`Sources/DroppyWindowBridge` with its upstream attribution.

The app icon is a native Icon Composer document in `SlipIcon.icon`, compiled with
Xcode 27 into layered `Assets.car` renditions and a legacy `SlipIcon.icns`.
`CFBundleIconName` selects the layered asset. macOS owns Default, Dark, Clear Light,
Clear Dark, Tinted Light and Tinted Dark; Slip never overrides or clears
`applicationIconImage`. The artwork is inset to fit neighbouring Dock icons.
No custom Finder icon or resource fork is installed. The source PNG retains its
transparent centre; the surrounding glass is rendered by macOS.

Auto Refresh, iPhone Apps, Activity and Settings use the same readable content
width, section labels, cards and spacing as Apple Accounts. App inventories use
quiet selectable rows rather than a stock List; Activity keeps privacy controls
and filtered copying together. Schedule details are disclosed as needed.

## Window focus regression check

The primary workspace is owned by AppKit through `SlipWindow`, which explicitly
allows key and main window focus. The window uses Droppy's titled construction,
allowing Apple Account fields, secure password entry and keyboard shortcuts to
receive events. The application delegate handles Dock reopening and incoming IPA
files/URLs; the automatic refresh worker still launches without a window.

Run `swift test --package-path native` from the repository root to verify keyboard
eligibility and field-editor acquisition for text and secure inputs. These tests do
not sign in to Apple or store credentials.

## Authentication and two-factor verification

Sign-in verification appears directly below the password, retains its place while
Apple verifies the code and prepares developer access, and reports failures in the
form. Installation and resource operations retain a separate verification panel.

Slip owns the authentication lifecycle, bounded recovery policy, provider isolation,
and developer-session storage. Apple protocol/cryptography, signing, and device
libraries remain dependencies. The account password and developer session secret
are stored in macOS Keychain; the session metadata file contains a provider-bound
reference. Old plaintext session caches require a fresh sign-in.

“This Mac” never switches to an external provider. Remote compatibility requires
an explicitly selected HTTPS service (or HTTP on loopback), including for automatic refresh; Slip does
not cycle through public providers. macOS may refuse local authentication data,
as it does on the currently tested macOS 27 installation. See
[the reliability notes](../docs/AUTHENTICATION_RELIABILITY.md) and
[local compatibility evidence](../docs/LOCAL_AUTHENTICATION_COMPATIBILITY.md).

Run `swift test --package-path native` for UI state, native focus, and child-process
protocol checks. Rust recovery/session tests use fake credentials and an in-memory
vault; they never submit real passwords, codes, or modify Apple developer resources.
