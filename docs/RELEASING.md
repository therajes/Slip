# Building and releasing Slip

GitHub Actions builds the native app and DMG from source. A local disk image is not an input to the workflow.

## Every push and pull request

Pushes to `main`, pull requests targeting `main`, and manual **Build Slip** runs:

1. Select Xcode 27.2 and Python 3.13, and verify that all five version manifests agree.
2. Run the Rust core tests and every Swift test.
3. Build the arm64 native app and bundled core.
4. Create the DMG, verify the compressed image, check the installer layout and app signature, and generate `SHA256SUMS.txt`.
5. Upload the DMG and checksum as a workflow artifact, retained for 14 days.

A failed test or packaging check stops the build. New pushes cancel superseded branch builds. They do not cancel version-tag release runs.

## Publish a version

Update `native/Info.plist`, `package.json`, `src-tauri/Cargo.toml`, the root `sideloom` entry in `src-tauri/Cargo.lock`, and `src-tauri/tauri.conf.json` to the same version. Add its changelog entry and `docs/RELEASE_NOTES_<version>.md`, then commit and push to `main`.

After the branch build passes, tag that tested commit. For Slip 3.0.0, only after explicit publishing approval:

```sh
git tag -a v3.0.0 -m "Slip 3.0.0"
git push origin v3.0.0
```

The tag starts a complete build. Once every check passes, a separate job downloads that run's artifact, verifies its checksum, and creates the GitHub Release with the DMG, checksum and version's release notes. A mismatched version tag is rejected. Existing tags and releases are not overwritten.

Use a new version for a later release. Branch pushes and manual builds do not publish releases.

## Signing

GitHub builds use ad-hoc signing because no Developer ID or notarization credentials are configured. The workflow verifies that signature, but these downloads are not Apple-notarized. macOS may require explicit approval to open them.

CI's signing identity differs from a locally development-signed installation. Replacing that app may require renewed Keychain access approval. Saved library and renewal files are not bundled into release artifacts.

Developer ID signing and notarization require an Apple Developer Program identity and corresponding GitHub secrets before they can be automated. Do not commit certificates, passwords, provisioning profiles or account data.

## Installer view metadata

Finder's icon view uses both `icvl` and `icvp`, following the
[dmgbuild implementation](https://github.com/dmgbuild/dmgbuild/blob/main/src/dmgbuild/core.py).
The background alias is generated from a canonical path so `/var` symlinks do not
create a reference outside the volume. Packaging verifies the volume-relative
background path as well as both icon-view records and the icon positions.


## Opt-in production distribution

Default builds do not require production credentials. For production signing, provision a Developer ID Application identity (including its private key) and a `notarytool` keychain profile securely on the trusted Mac runner. Never export them into the checkout. Set `SLIP_PRODUCTION_SIGNING=1`, `SLIP_DEVELOPER_ID` to the identity name and `SLIP_NOTARY_PROFILE` to the profile name. Run the normal build and DMG commands. Missing credentials fail the opted-in build instead of falling back to a misleading production label.

CI uses the repository variable `SLIP_PRODUCTION_SIGNING=1` and secrets `SLIP_DEVELOPER_ID` / `SLIP_NOTARY_PROFILE` for those references. The identity and profile must already exist in the runner's unlocked keychain. Keep this mode disabled for untrusted pull requests and use an isolated trusted release runner. No certificate import, secret echoing or keychain export occurs in the workflow.

`native/production-sign.sh` signs helpers before the app with Hardened Runtime and a secure timestamp, verifies signatures, submits the app ZIP and then the DMG, staples both artifacts and runs `spctl`. A successful script is required before CI labels a production artifact notarized. No production notarization is claimed merely because this support exists. Without the installed identity, private key and notary profile, production distribution remains blocked; local completion is unaffected.

## 2.8 validation

Run all commands listed in [the manual matrix](MANUAL_TEST_MATRIX_2.8.0.md). Record exact results in the release report. Never infer live SMS, USB/Wi-Fi, notification delivery or Gatekeeper results from unit tests. Do not tag or publish a release without explicit approval.


## 3.0 local-first release gate

The user tests the installed local candidate first. Do not push, tag, publish or automatically replace it from a feed until the user gives the release flag. Run the exact existing tests/build/DMG commands and record results separately from live user verification. Generate evidence with `python3 native/release-evidence.py native/dist/Slip-3.0.0.dmg native/dist`. Scanner tools are optional: missing tools are NOT RUN, not a clean security result; findings require review. SPDX output inventories Cargo.lock and does not claim all OS/framework dependencies or audited licenses.

Production mode additionally requires `SLIP_DEVELOPER_TEAM_ID`, matching the installed Developer ID identity. Verification checks app/core/helper version, identifiers, arm64 architecture and signatures; production mode additionally checks Hardened Runtime, timestamp and expected team before notarization. Signing references must be preinstalled in an isolated trusted runner keychain; private keys/passwords never enter the checkout, CLI arguments or logs. Clean-machine Gatekeeper acceptance remains a separate manual gate.

After a tested release is approved, publish the DMG, checksum, PROVENANCE.json and SBOM.spdx.json from the tag workflow. Provenance records commit, dirty worktree flag and lock/artifact hashes. An SHA-256 file is corruption evidence, not an independent authenticity trust anchor.

Rollback: retain the previous signed app and private data checkpoint. Quit Slip normally after active operations stop, stage the replacement, verify bundle/signing identity and rename with rollback. Never restore an older metadata snapshot over newer user edits without explicit review; never export/reset Keychain or pairing material. A signing-team transition can require renewed Keychain permission. Current 3.0 does not provide a silent updater or privileged installation helper.
