# Slip 2.8 real-device and release validation

Every row below starts **NOT RUN for 2.8**. Record date, Mac/iOS versions, account type and transport locally; never include raw UDIDs, credentials, SMS codes or pairing records in reports. The owner's live 2.7 SMS confirmation is established baseline evidence, not a 2.8 physical test.

| Scenario | Expected result |
| --- | --- |
| SMS-only account, one and multiple trusted numbers | Correct number selection, single initial challenge, selecting active number preserves code; explicit resend; six-digit rules and SMS wording unchanged |
| Trusted-device 2FA, rejected/expired code, interaction needed in background | Existing challenge retained; foreground authentication offered; no headless prompt loop |
| USB trusted/untrusted, Developer Mode off, disconnect | Evidence-based guidance; unknown trust remains unknown; no pairing reset offered |
| Wi-Fi install, network switch, USB fallback | Intended physical device remains target; unavailable inventory produces pending verification |
| Free and paid team, existing IDs and extensions | Correct identity reuse, timestamps and estimated versus authoritative resource status; no informational registration |
| Multi-extension app, wildcard, keychain groups, entitlement mismatch | Component-specific evidence; generated profile checked; limitations explicitly reviewed before transfer |
| Missing profile, malformed/encrypted executable, architecture mismatch | Block or unknown based on evidence; original IPA preserved |
| ZIP traversal, duplicates/case collisions, symlink, excessive expansion | Safe rejection with user-facing reason; no files outside owned temporary storage |
| Interrupted process at sign/transfer/install/verify; quit and restart | Prior valid library state retained; reconciliation checks inventory before any new install |
| Inventory unavailable after transfer | Verification Pending; no false installed history or confirmed expiry |
| App update with changed effective identity | Warning that it may install separately; saved/source/installed versions distinguishable |
| Queue cancellation and failure | Sequential execution and file lease retained; cancellation not reported as generic failure |
| Refresh after sleep/wake, missing IPA and expired authentication | Source lookup or foreground auth recovery; no silent success or unbounded retries |
| Notification first run, denied, disabled alerts, quiet mode and each action | GUI-owned permission, private banner text, foreground action and operation lease; no headless authorization request |
| VoiceOver, keyboard, narrow window, large text, Reduce Motion/Transparency | Readable stages/cards and accessible controls within existing glass UI |
| Upgrade from 2.7 with existing library, managed IPA and renewal schedules | Existing references and Keychain/session access retained; no data loss |
| Production app and DMG | Developer ID/Hardened Runtime signatures, notary acceptance, staple validation and Gatekeeper checks only with supplied credentials |

Automated and packaging commands (lead must record actual PASS/FAIL/NOT RUN):

```sh
cargo test --manifest-path src-tauri/Cargo.toml --locked --no-default-features --lib
cargo test --manifest-path src-tauri/Cargo.toml --locked -p isideload --lib
swift test --package-path native
./native/build.sh
./native/create-dmg.sh native/build/Slip.app native/dist/Slip-2.8.0.dmg
```

Use synthetic fixtures for secret-injection checks. Preview support reports and confirm passwords, tokens, six-digit codes, email addresses, UDIDs, local paths and pairing material are absent. Keep any physical account/device evidence outside version control. No personal code or credential is needed by an automated agent.
