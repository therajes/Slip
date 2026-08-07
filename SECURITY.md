# Security policy

## Reporting

Please open a private GitHub security advisory for credential handling, signing, pairing, archive processing, or device-communication vulnerabilities. Do not include Apple Account passwords, two-factor codes, pairing records, device UDIDs, certificates, or provisioning profiles in a public issue.

## Credential model

Slip stores an Apple Account password only when the user enables credential saving. The item is owned by the Slip bundle identifier in macOS Keychain. At install time, the SwiftUI process retrieves it and sends it to the bundled core through an anonymous stdin pipe. It is never placed in a command-line argument, environment variable, refresh recipe, or activity log.

## Scope

Slip is intended for IPAs and iPhones the user is authorized to operate. Security issues do not include bypassing Apple's app-count, certificate, provisioning, Developer Mode, or profile-expiration policies.
