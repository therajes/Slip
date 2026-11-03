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

After the branch build passes, tag that tested commit. For Slip 2.5.0:

```sh
git tag -a v2.5.0 -m "Slip 2.5.0"
git push origin v2.5.0
```

The tag starts a complete build. Once every check passes, a separate job downloads that run's artifact, verifies its checksum, and creates the GitHub Release with the DMG, checksum and version's release notes. A mismatched version tag is rejected. Existing tags and releases are not overwritten.

Use a new version for a later release. Branch pushes and manual builds do not publish releases.

## Signing

GitHub builds use ad-hoc signing because no Developer ID or notarization credentials are configured. The workflow verifies that signature, but these downloads are not Apple-notarized. macOS may require explicit approval to open them.

CI's signing identity differs from a locally development-signed installation. Replacing that app may require renewed Keychain access approval. Saved library and renewal files are not bundled into release artifacts.

Developer ID signing and notarization require an Apple Developer Program identity and corresponding GitHub secrets before they can be automated. Do not commit certificates, passwords, provisioning profiles or account data.
