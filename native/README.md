# Slip Native

Slip Native is the SwiftUI macOS application. On macOS 26 and newer it uses Apple's native Liquid Glass APIs; earlier supported releases receive a system-material fallback. It bundles a separate Rust executable for Apple signing and iPhone communication.

## Architecture

- SwiftUI/AppKit: windowing, navigation, drag and drop, file import, sheets, progress, accessibility.
- Security.framework: Apple Account passwords stored as generic-password items owned by `app.sideloom.native`.
- `sideloom-core`: internal newline-delimited JSON process protocol; handles IPA inspection/customization, Apple developer signing, usbmuxd/AFC, network devices, and Installation Proxy.
- Passwords are sent to the child core through an anonymous stdin pipe, never command-line arguments or environment variables.

## Build

Run `./build.sh`. The signed application is written to `native/build/Slip.app`.

Run `./create-dmg.sh build/Slip.app dist/Slip-1.0.0.dmg` to create the visual drag-to-Applications installer.
