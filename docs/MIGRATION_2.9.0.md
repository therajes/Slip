# 2.9 preservation and troubleshooting

Library version 1 remains supported; new queue deployment fields are optional. Legacy entries retain their review flow. Account sessions and Keychain references are unchanged. No destructive data migration is performed.

Backups use schema 1 checksummed JSON envelopes with a .slipbackup extension, bounded to 360 MiB. Only typed nonsecret metadata and explicitly selected regular IPA copies are exported. Feed query/credential components are removed and cached releases are excluded from per-app subscriptions. Imported workspaces are merged by UUID; local conflicts win. Imported queue approvals are discarded, devices cleared and automatic renewal disabled. Locate missing IPA paths, pair the device, authenticate and review before installation. This is not an iPhone private-data backup.

An interrupted restore leaves a rollback manifest; the next library startup restores prior metadata before loading. Disk-full recovery may require free space before rollback can complete. Existing malformed libraries are preserved rather than overwritten.

If a deployment is Unknown, reconnect the exact intended device and verify before retry. Missing devices/accounts wait; reviewing changed targets replaces stale approval. Catalog refresh errors retain cached entries labeled stale. Remove a source to discard its index; this does not uninstall apps. Publisher and download-host identity are unverified claims visible before download. DNS checks retain the 2.8 rebinding limitation.

Manual validation: two physical devices including disconnect/sleep; SMS-number/resend flow; kill during signing/transfer and verify-only restart; GUI/LaunchAgent contention; backup clean-user import/corruption/disk full; VoiceOver/keyboard/narrow layouts; production signing when credentials exist. No such checks are inferred from unit tests. Profile Instruments launch, scrolling and idle load before making performance claims.
