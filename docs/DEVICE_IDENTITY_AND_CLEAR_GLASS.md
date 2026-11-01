# Device identity and clearer glass

The authentication fallback described below records the earlier UI release.
Slip 1.3.0 supersedes it with strict local mode and explicit provider selection;
see [authentication reliability](AUTHENTICATION_RELIABILITY.md). The UI adaptation
and historical validation notes remain for reference.

The material description below is also historical. Slip 2.1.3 uses the installed
Droppy Code 1.7.0 Liquid Glass renderer on macOS 26+, with the active SDK recorded
at link time. See [the current backdrop implementation](BACKDROP_VERSION_PARITY.md).

The native app now reads this Mac's computer name, model identifier, macOS version,
and build directly from macOS. New signing certificates use the computer name.
Apple Account settings show the detected details and authentication source.

“This Mac” requests authentication data from the local AOSKit service. When macOS
does not provide it, Slip switches to remote compatibility **before credentials
are sent**, shows an informational notice, and continues the ordinary sign-in
flow. It keeps the selected preference and scopes cached sessions to the effective
provider. Password failures, two-factor rejection, and rate limits do not trigger
this fallback. Existing requests and preferences retain remote compatibility.

The availability probe on this Mac (`Mac17,3`, macOS 27.0) returned no local
authentication data. Remote authentication preparation succeeded using
`https://ani.sidestore.io`. The remote provider may still cause Apple to display
a different device; local hardware metadata alone cannot turn a remote-generated
identity into this Mac's identity or guarantee Apple's alert wording.

Implementation references:

- [AltStore's native AOSKit implementation](https://github.com/altstoreio/AltStore/blob/marketplace/AltServer/Anisette%20Data/AnisetteDataManager.swift)
- [Anisette maintainer's platform-compatibility discussion](https://github.com/Dadoum/anisette-v3-server/issues/61)

The interface now directly reuses adapted window-chrome and material code from the
local Droppy Code source at `/Users/rajeshbarik/Downloads/droppy-code-main`, ported
in `native/Sources/SideloomNative/DroppyChrome.swift`. There is no sidebar. Floating
navigation capsules provide Install, Auto Refresh, iPhone Apps, Apple Accounts,
and Activity, with Command-1 through Command-5 shortcuts. The controls align with
the native window buttons. Install uses an open, centered IPA workspace, a compact
device strip, flat customization sections, and a readiness disclosure; the large
Destination, IPA, and Preflight cards have been removed. The install action panel
floats with margins rather than drawing an opaque bar.

The background follows Droppy's `UI/Chrome/Chrome.swift`: one active native
`underWindowBackground` material blending behind the window, a 26-point rounded
mask, a black 26% scrim in dark mode or white 18% scrim in light mode, a neutral
12% wash, and a quiet one-point rim. Page wrappers are transparent. Floating cards
reuse Droppy's regular glass surfaces with neutral washes instead of solid page
backgrounds. Ordinary GroupBox sections have no heavy glass backing. Reduce
Transparency and increased contrast retain solid alternatives. Droppy Code's
reference repository was not modified. Its AGPLv3 license with additional terms,
complete third-party notices, and user-visible About credits are included; see
`native/LICENSE`, `native/THIRD_PARTY_NOTICES.md`, and the README licensing sections.

Validation completed:

- 19 Rust library regression tests passed.
- Rust, Swift, and Objective-C helper release builds passed; bundle signatures verify.
- 15 packaged-core checks passed, including the existing IPA regressions.
- Six native protocol/lifecycle and legacy-request compatibility checks passed.
- Host metadata matches system values; helper diagnostics omit authentication tokens.
- Local-unavailability fallback is emitted before credential validation and no
  longer ends in a device-identity error.
- A real remote authentication preparation check returned `ready` without using
  an Apple Account password or verification code.
- Installed `/Applications/Slip.app` matches all three built executable hashes
  and launches with a responding bundled core.

The floating-navigation UI release build and signature checks passed on
2026-10-26. The installed bundle's three executable hashes match the build, the
application opens through Finder, and its bundled core responds.

Rollback copy before the direct source port:
`/Users/rajeshbarik/Library/Application Support/Slip/Backups/Slip-20261026-082724.app`.

Live Apple Account sign-in, resource deletion, and device installation were not
performed. Droppy Code's running main window, the supplied comparison screenshots,
and Slip's installed main window after the direct source port were visually
inspected. The desktop helper still fails intermittently during navigation, so
the automated navigation interaction check is not recorded as passed.
