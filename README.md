![Slip — Your iPhone apps. A native Mac home.](design/repository-header.svg)

Inspect, customize, install, and refresh IPAs in a Liquid Glass workspace.

[![Build Slip](https://github.com/therajes/Slip/actions/workflows/build.yml/badge.svg)](https://github.com/therajes/Slip/actions/workflows/build.yml) ![Slip 2.7](https://img.shields.io/badge/Slip-2.8-64748b?style=flat-square) ![macOS 26 or newer](https://img.shields.io/badge/macOS-26%2B-24292f?style=flat-square&logo=apple&logoColor=white) ![Built with SwiftUI and Rust](https://img.shields.io/badge/SwiftUI_%2B_Rust-native-777?style=flat-square)

[**Download Slip**](https://github.com/therajes/Slip/releases/latest) · [What's new in 2.8](docs/RELEASE_NOTES_2.8.0.md) · [Screenshot gallery](docs/GALLERY.md) · [Source](https://github.com/therajes/Slip/tree/main)

![Slip 2.7 App Library with cached artwork and update controls](design/screenshots/2.7/slip-library.png)

Slip brings SwiftUI and AppKit together with a Rust core for IPA preparation, Apple signing, and direct iPhone transfer. Save workspaces in an App Library, review each install, and keep refresh recipes beside the apps they belong to.

## How it works

| Make it yours | Keep it organized | Stay connected |
| :--- | :--- | :--- |
| Drop an IPA or import from Finder or HTTPS. Inspect artwork, identity, versions, extensions, and App ID cost before signing. | Keep saved workspaces in the App Library. Import multiple IPAs and review a sequential installation queue. | Install over USB or a paired local network. Browse the connected iPhone's apps and manage saved refresh recipes. |
| Change the Home Screen name, bundle ID, icon, minimum iOS version, and supported plist values. Keep or remove individual extensions, or export a customized IPA. | Resume your choices, follow preparation and transfer progress, and find past actions in Activity with privacy redaction. | Refresh Guard can re-sign saved apps about 24 hours before a free profile expires, when the Mac and paired iPhone are reachable. |

| | |
| :--- | :--- |
| ![Slip 2.6 Auto Refresh workspace](design/screenshots/2.6/slip-autorefresh.png) **Refresh, at a glance** Saved recipes and renewal status in one place. | ![Slip iPhone app inventory](design/screenshots/slip-iphoneapps-dark.png) **A view of your iPhone** App inventory, explicit selections, and device actions. |
| ![Slip 2.5 appearance and behavior settings](design/screenshots/2.5/slip-settings.png) **Comfortably native** Theme and backdrop controls, with system accessibility preferences. | ![Slip drag-to-Applications disk image](design/screenshots/2.6/slip-dmg.png) **Drag. Drop. Open.** A familiar macOS installer. |

Auto Refresh and the disk image are captured from 2.6. Settings and device inventory images are retained from earlier releases. Explore the [gallery](docs/GALLERY.md) or [feature matrix](docs/FEATURE_MATRIX.md) for more.

## New in 2.8

Installation Readiness adds versioned evidence about source entitlements, archive integrity and signing limitations. Source provisioning is preliminary; generated profiles are checked before transfer. Install outcomes require inventory confirmation on the intended iPhone, otherwise verification remains pending. Typed recovery cards, sanitized reports and native quiet notifications make uncertainty visible.

Slip 2.7 SMS-only sign-in was confirmed working by the owner. The authentication semantics are preserved. See [2.8 release notes and validation limits](docs/RELEASE_NOTES_2.8.0.md).

## Included from 2.7

- **SMS sign-in fix.** Accounts using phone verification follow Apple's SMS challenge and actual trusted-number IDs. Selecting the same destination preserves its current code.
- **Updates in App Library.** Follow developer GitHub releases or an HTTPS AltStore source. Review versions, release notes, iOS requirements and available IPA assets.
- **Saved choices for updates.** Prepare a bundle-validated IPA with existing customizations, then review before signing and installing.
- **Artwork and history.** Actual cached app icons replace generic rows. Version history distinguishes saved IPAs from confirmed installations.
- **Reusable presets.** Save preparation choices and apply them to another workspace for review.
- **Managed storage.** Optionally keep verified IPA copies inside Slip. Inspect usage and preview cleanup that protects workspace, queue and renewal references.

Open **Updates…** beside an app, or use **More → Manage App…** for presets, history and storage. Read the [2.7 release notes](docs/RELEASE_NOTES_2.7.0.md) for behavior and validation limits. Renewal and recovery improvements from [2.6](docs/RELEASE_NOTES_2.6.0.md) remain included.

## Get started

**You'll need:** an Apple-silicon Mac running macOS 26 or newer, a personal iPhone, an Apple Account, and an IPA you are authorized to use.

1. [Download the latest available `Slip-*.dmg`](https://github.com/therajes/Slip/releases/latest) and drag Slip to **Applications**.
2. Connect the iPhone over USB, trust the Mac, and enable **Developer Mode** on the iPhone.
3. Add your Apple Account. Password storage in macOS Keychain is optional; unattended Refresh Guard requires it.
4. Drop an IPA into Slip, review its details and customizations, then select **Sign & Install**.

For Wi-Fi discovery, Finder must first recognize the paired iPhone, and both devices must share a normal local network. Personal Hotspot routing can prevent peer discovery. Slip supports `slip://install?url=…` for direct IPA links.

### Refresh Guard and free accounts

Apple Personal Team profiles expire after seven days, and stock iOS limits free accounts to three active sideloaded apps. Slip works within those limits. Refresh Guard performs a normal re-sign and reinstall; the Mac must be awake, the saved IPA and opted-in Keychain credentials available, and the paired iPhone reachable over Wi-Fi or USB.

Slip targets personal iPhones. Apple TV, Apple-silicon Mac app installation, jailbroken-device workflows, and permanent signing are outside its scope.

## Build from source

The native release uses **Xcode 27.2 / macOS SDK 27.2**, with a **macOS 26** deployment target. Install Xcode command-line tools and Rust on an Apple-silicon Mac, then run:

```sh
./native/build.sh
./native/create-dmg.sh native/build/Slip.app native/dist/Slip-2.8.0.dmg
```

For the native architecture and development details, see [native/README.md](native/README.md).

GitHub Actions runs the tests and builds a DMG on every push to `main`. Version tags publish that GitHub-built DMG and its SHA-256 checksum to Releases. See [the release workflow](docs/RELEASING.md).

Default automated builds are locally signed without production notarization. Opt-in Developer ID signing, Hardened Runtime, notarization and stapling are available when a trusted runner has securely provisioned credentials; see [release instructions](docs/RELEASING.md).

### Development checks

```sh
cd src-tauri
cargo fmt --check
cargo check --no-default-features --bin sideloom-core
cargo test --no-default-features --lib
cd ../native
swift build -c debug
swift test
```

## Privacy and security

Signing, customization, and device communication happen locally, apart from requests to Apple developer services and the configured anisette service. Slip has no analytics or account server. Passwords reach the bundled core through an anonymous stdin pipe, never command arguments or logs; Keychain storage requires explicit consent.

Apple Account profiles support verified names, local avatars, and two-factor prompts that remain visible during developer-session setup. "This Mac" never silently switches authentication providers. Remote compatibility requires an explicitly selected HTTPS endpoint, and local authentication can be unavailable on newer macOS versions. Read [authentication reliability and current limits](docs/AUTHENTICATION_RELIABILITY.md).

Preflight checks reject encrypted IPAs, incompatible iOS targets, invalid bundle IDs, missing icons, duplicate keys, and unsafe identity overrides before signing. Only install or modify apps you are authorized to use. See [SECURITY.md](SECURITY.md) to report a sensitive issue.

## Credits and license

Slip is an independent continuation built on the MIT-licensed foundations of [iLoader](https://github.com/nab138/iloader), [isideload](https://github.com/nab138/isideload), and [idevice](https://github.com/jkcoxson/idevice). It does not contain or redistribute Sideloadly code, assets, branding, or paid-service mechanisms.

The native interface includes modified window and glass UI code from **Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app** ([project website](https://getdroppycode.app)), Copyright (c) 2026 Jordy Spruit (Droppy). Slip's adaptation is modified and is not affiliated with or endorsed by Droppy or Jordy Spruit. Slip retains its own name, icon, and branding.

The combined native application incorporating that UI is available under GNU AGPL version 3 with Droppy Code's additional attribution, origin, and trademark terms; see [native/LICENSE](native/LICENSE) and the preserved [third-party notices](native/THIRD_PARTY_NOTICES.md). The original MIT-licensed Slip/iLoader code and Rust core retain their existing copyright and [MIT license notices](LICENSE), including Copyright (c) 2025 nab138. This does not replace those original notices or claim ownership of upstream code.

The corresponding source and build scripts are included in this repository. Distributing a build requires providing its corresponding source and notices under the applicable license terms. The app bundles its license texts and displays attribution in About Slip.

Original iLoader branding terms remain documented in [LICENSE-BRANDING](LICENSE-BRANDING). Slip is not affiliated with Apple, Sideloadly, or the iLoader maintainers.
