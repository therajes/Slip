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

After the branch build passes, tag that tested commit. For Slip 2.8.0, only after explicit publishing approval:

```sh
git tag -a v2.8.0 -m "Slip 2.8.0"
git push origin v2.8.0
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
