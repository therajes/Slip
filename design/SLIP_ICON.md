# Slip icon

The current icon uses two flowing app tiles with a transparent transfer cutout.
Its graphite/platinum gradient replaces the earlier green version. The source
artwork's exterior and centre are alpha transparent. The native Icon Composer
document at `../native/SlipIcon.icon` supplies the foreground and material
annotations; macOS renders the surrounding glass for the selected system style.
The app does not supply a flattened Dock-image override.

- `slip-symbol-source.png`: final source artwork from the built-in image tool.
- `slip-icon.png`: 1024-pixel production image; visible artwork fits an
  800-pixel box with transparent optical padding to match neighbouring Dock icons.
- `../native/IconRenderer.swift`: reproducible sizing and PNG export; retains alpha.
- `../native/SlipIcon.icon`: native layered icon, compiled by Xcode 27.
- `../src-tauri/icons/icon.icns`: compiler-produced fallback for older macOS.

Default, Dark, Clear Light, Clear Dark, Tinted Light and Tinted Dark are rendered
from the same layered document. Their 512-pixel previews are generated with
Apple's `ictool --design-generation 27`; the compiled asset catalog contains
the Aqua, Dark Aqua and Tintable image stacks that the system uses for them.

The native light/dark image assets and the web logo retain the production PNG.
The previous app is retained locally in
`native/build/Slip-2.0.0-before-icon-backdrop.zip`.

## Generation record

Created and edited with the built-in `image_gen` tool, using the imagegen skill.
The final edit used the approved transparent teal symbol as its reference and
this prompt:

> Recolor ONLY this approved Slip logo, preserving its exact geometry and design.
> Replace the emerald green/cyan palette with an understated premium GRAPHITE AND
> COOL PLATINUM palette. Upper rounded tile has a very soft gradient from light
> cool platinum silver at upper-left to medium slate graphite along its lower
> folded edge. Lower rounded tile flows from medium cool graphite to deep
> charcoal at bottom-right. Subtle satin finish, smooth restrained tonal
> transitions, crisp silhouette, no chrome shine, no metallic frame, no neon,
> no colored glow. Quietly luxurious and elegant, light upper tile and dark lower
> tile give clear visual separation and readability on both dark and light
> desktop backgrounds. Keep the small curved internal fold and all existing soft
> blend transitions. BOTH the outer background AND the downward-arrow-shaped
> centre cutout MUST remain genuinely transparent alpha; do NOT refill the centre
> with white or silver, the desktop must show through it. The gradients stay on
> the rounded tile surfaces and softly blend at their edges. No letters or text,
> no background square, no new shapes, no redesign or altered proportions, no
> heavy shadows. Clean smooth antialiased exterior and inner edges without stray
> pixels or fringe. Output production transparent PNG.

The colour and cutouts were inspected in the final 1024-pixel PNG and its
128-pixel ICNS representation. Pixel checks confirm zero alpha outside the mark
and in the central cutout, with opaque tile interiors.

Native format references: [Icon Composer](https://developer.apple.com/icon-composer/)
and [Apple's icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).
