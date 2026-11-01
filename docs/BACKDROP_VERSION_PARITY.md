# Backdrop version parity

The visual reference is the installed Droppy Code **1.7.0**, not the newer
`droppy-code-main` source archive in Downloads. The archive uses an active
`NSVisualEffectView` with `underWindowBackground`; the installed version uses
SwiftUI Liquid Glass. This version mismatch caused Slip's earlier heavier blur.

The pinned [upstream 1.7.0 Chrome.swift](https://gitlab.com/droppyformac1/droppy-code/-/blob/v1.7.0/DroppyCode/UI/Chrome/Chrome.swift)
is reproduced in `Droppy17WindowBackdrop` in
`native/Sources/SideloomNative/DroppyChrome.swift`, unchanged apart from the type
name. The default renderer is `glassEffect(in:)`,
followed by the stock slider scrim, 12% theme wash and one-point rim. At 0% the
additional scrim is zero; the system still renders the glass. Theme appearance is
forwarded at the SwiftUI root as well as through AppKit, matching Droppy's host.

Slip 2.1.3 requires macOS 26 or newer. The older native-material rendering paths
have been removed. Solid alternatives remain for Reduce Transparency, increased
contrast and performance mode; they do not run with those settings disabled.

The macOS 27 toolchain's SwiftPM Xcode path initially wrote `sdk 15.0` into
`LC_BUILD_VERSION`, despite compiling against the macOS 27 SDK. The production
build now passes `-platform_version macos 26.0 <active-sdk-version>` to the linker.
The deployment target is now 26.0; the SDK is read from `xcrun`, not hard-coded
or patched into an already-built executable. Droppy's installed executable also
uses SDK 27.0 with a minimum OS of 26.0. No extra brightness wash was added.

The toolbar's outer capsule owns the glass. Inner controls use a small neutral
selection wash and a short press response, without an extra circular bezel or
muted accent on the selected symbol. Reduce Motion and the animation preference
disable the animated press effect.

The UI update preserves the installed core, anisette helper and native icon
assets. Release build logs, executable metadata, signature and hash checks are
recorded under the ignored `native/build/backdrop-parity` directory. Live
window-only capture omits desktop samples from the system glass, so those
captures can validate controls and layout but cannot establish a pixel-identical
desktop backdrop comparison.
