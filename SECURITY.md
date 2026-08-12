# Security policy

## Reporting

Please open a private GitHub security advisory for credential handling, signing, pairing, archive processing, or device-communication vulnerabilities. Do not include Apple Account passwords, two-factor codes, pairing records, device UDIDs, certificates, or provisioning profiles in a public issue.

## Credential model

Slip stores Apple Account passwords as items owned by the Slip bundle identifier in macOS Keychain. At install or App ID lookup time, the SwiftUI process retrieves the credential and sends it to the bundled core through an anonymous stdin pipe. It is never placed in a command-line argument, environment variable, refresh recipe, preference, or activity log. The Rust request buffer is zeroed immediately after Apple authentication completes.

Refresh recipes and downloaded IPAs are stored only in Slip's Application Support container. Credential-adjacent files are created with owner-only permissions. App and device operations use a cross-process lease so the foreground app and Refresh Guard cannot mutate one iPhone session concurrently.

## Archive and network boundaries

IPA processing rejects absolute paths, parent traversal, links, duplicates, multiple top-level apps, excessive entry counts, oversized plists/icons, unsafe bundle IDs, and arithmetic overflow while inspecting Mach-O data. HTTPS downloads use an ephemeral session, explicit timeouts, a 4 GB response limit, and owner-only temporary files.

## Dependency advisory

Slip 2.0.0 includes `rsa 0.9.10` transitively through the Apple code-signing stack. [RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html) describes a timing side channel in RSA private-key operations and currently has no patched RustCrypto release. Slip uses this path locally for developer signing, certificate requests, and device pairing rather than as a remote decryption oracle. The risk remains documented and CI ignores only this exact advisory until the upstream signing dependency can remove or replace it; all other advisories still fail the build.

## Scope

Slip is intended for IPAs and iPhones the user is authorized to operate. Security issues do not include bypassing Apple's app-count, certificate, provisioning, Developer Mode, or profile-expiration policies.
