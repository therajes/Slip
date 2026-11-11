# 3.0 support and compatibility

Supported target remains Apple silicon, macOS 26+, personal iPhone over verified USB or paired local network; free and paid legitimate Apple Accounts subject to Apple's limits. macOS must be available. Intel, Windows, Apple TV, JIT bypass, injection, iPhone-only signing and private app-data restore are not supported.

macOS 15 was audited as an experiment, not advertised. Unguarded GlassEffectContainer/glassEffect calls occur in SlipGlassStyle, DroppyChrome, FloatingWorkspacePanel and IPhoneModelPreview; native Package.swift/build deployment and helpers target macOS 26. Conditional fallback materials would require coordinated changes and real macOS 15 signing/device tests. No target was lowered without evidence.

Tests are separate: deterministic automated policy/regression checks; owner-performed real account/device validation; production Developer ID/notary/staple; clean-Mac Gatekeeper; accessibility/locale; Instruments. Neither CI green nor local codesign verification proves a physical install or Apple notarization.
