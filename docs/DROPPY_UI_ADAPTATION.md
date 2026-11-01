# Slip native interface adaptation

The reference is the local `~/Downloads/droppy-code-main` checkout. The application
remains Slip, with its own icon, IPA installation engine and account/device workflows.
The interface adaptation preserves upstream credits, AGPL/additional terms and notices.

## Accepted design requirements

- Navigation is a movable, resizable floating glass panel over a full-width workspace.
  It never reserves a sidebar column. The toolbar list button and Command-Shift-S
  toggle it. Selecting a destination closes the panel.
- Use continuous 26-point window corners and 22-point floating panel corners.
  Clip each surface to the shape used by its material and hairline. The native
  window uses an AppKit-owned, focusable borderless `SlipWindow`, removing the native title-bar frame that
  produced a second dark curve. Real AppKit traffic-light buttons are hosted
  separately, with native close, minimize, zoom and full-screen actions. Refit
  the clear frame layer after layout and refresh its window-server shadow.
- Keep the SwiftUI scene and AppKit window clear. Use one behind-window blur,
  without an additional dark detail sheet. The initial backdrop opacity is zero,
  matching the installed Droppy Code setting checked during implementation.
- The IPA toolbar action uses `tray.and.arrow.down`, with Command-O and an accessible
  Open IPA label. A pencil is a misleading icon for this action.
- Follow the current macOS control accent and semantic label colors by default;
  do not force blue. Enabled navigation icons use the primary label color rather
  than muted secondary gray. Named themes supply their own accents when chosen.
  Prominent text buttons have white labels. The home import actions use large
  file-archive and link icons with tooltips and accessibility labels; no visible
  Choose an IPA or From URL text is rendered on those buttons.
- Wi-Fi appears inside the iPhone outline, and a USB connector appears outside it.
  The device picker, navigation panel and install panel share the same glyph.
- Use native controls, native drag handles and trackpad haptics. Connection previews
  settle once; no decorative idle animation repeats. Respect Reduce Motion,
  Reduce Transparency and increased contrast. Haptics can be turned off in Settings.

## Source map

- `AppTheme.swift`: upstream theme palettes, swatches and dynamic theme colors.
- `WorkspaceComponents.swift`: upstream sidebar rows, search, toolbar capsules and cards.
- `DragHandle.swift`: upstream AppKit drag handle and panel adapter.
- `FloatingWorkspacePanel.swift`: `FloatingSidebarPanel` adapted to Slip navigation,
  preference storage, accessibility and solid alternatives for accessibility and performance settings.
- `DroppyChrome.swift`: window configuration, traffic-light placement, glass surfaces,
  desktop blur and shared measurements.
- `ContentView.swift`: full-width workspace, floating navigation and device picker.
- `NativeWindowControls.swift`: native traffic lights and window dragging for the
  plain window, with a single visible window outline.
- `InstallView.swift`: IPA welcome/import, customization and floating action panel.
- `DeviceConnectionGlyph.swift` and `IPhoneModelPreview.swift`: compact connection
  language and model-aware phone preview.
- `AppearanceController.swift`: themes, zero-opacity migration, motion and haptic settings.

## Validation

Release packaging is performed by `native/build.sh`, including the Rust core,
SwiftUI executable, authentication helper, resources, notices and signatures.
The installed bundle is checked with `codesign --verify --deep --strict` and its
main executable is compared with the built artifact. The pre-redesign application
is preserved in `native/build/Slip-before-redesign-2026-10-26.zip`.

The running app was inspected for navigation, settings, panel movement, connection
selection, keyboard navigation, and the corresponding accessibility labels.
Apple Account sign-in, signing and iPhone installation are not exercised by this
visual verification; haptic feel requires supported physical hardware.

## Keyboard focus repair (1.2.1)

The SwiftUI plain scene window did not reliably become the key/main window, allowing
button actions while preventing credential typing. The AppKit application delegate
now owns a `SlipWindow` subclass with explicit `canBecomeKey` and `canBecomeMain`
overrides. Its SwiftUI content and approved appearance are unchanged. Dock reopening,
menu actions and URL/file opening route through that window. Two AppKit regression
tests cover keyboard eligibility and field editors for normal and secure text fields.

The user confirmed that the installed 1.2.1 Apple Account field accepts typing after
this repair. No credentials were supplied to the agent or submitted by the tests.
