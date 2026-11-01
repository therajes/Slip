# Slip 2.4 — App Library and installation queue

Open **App Library** in the floating navigation panel (⌘6). Existing navigation shortcuts, the approved backdrop, and icon are preserved.

## Saved workspaces

Opening a verified IPA creates a library entry. Slip saves its name, bundle ID, icon reference, extension choices, advanced settings (including unfinished plist rows), chosen account and iPhone, and Keep refreshed preference. Edits are saved after a short debounce, before switching apps, and before quitting. The last workspace is re-inspected and restored on launch; signing never starts automatically.

The library references the original files. It does not duplicate large IPAs, retain download URLs or their tokens, or put passwords, verification codes or developer sessions in its document. Passwords remain in Keychain. Library metadata is stored with owner-only permissions in `~/Library/Application Support/app.sideloom.native/Library/workspaces-v1.json`.

If an IPA disappears, **Locate IPA…** restores its reference after checking the bundle identity. If its metadata or file stamp changes, queued review is invalidated. A missing custom icon is reported by the existing readiness checks. Removing an entry keeps the original file and existing Auto Refresh schedule. An unreadable or newer library file is preserved rather than overwritten.

## Queue

Drop or choose multiple IPAs to add them in the order supplied by Finder. Duplicate file paths within the batch are ignored. Each app begins with **Review required**. Open **Review**, choose its account, iPhone, and customizations, then press **Save to Queue**. A single prepared app can also be added using **Queue** in the installation dock.

The queue displays the reviewed app, version, account and destination. Move pending entries earlier/later or remove them individually. **Install Queue** becomes available when every pending entry is reviewed. It installs one app at a time using a snapshot of its reviewed choices. Each source is re-inspected, the saved iPhone rediscovered, and readiness checked before requesting credentials. It uses Slip’s existing interactive 2FA and certificate selection flows.

The first failed/cancelled install stops the queue and leaves later entries pending. Use **Review & Retry** to correct a failed item. Stop Queue cancels the current signing flow where possible and prevents the next app from starting. Removing a pending item skips it without touching files. Interrupted installs become Review required after relaunch; Slip cannot assume whether an interrupted device transfer finished. Check the iPhone before retrying.

The existing foreground/background operation lease still serializes actual signing and renewal. A competing operation can stop the queue with a readable message rather than causing overlapping Apple requests. Auto Refresh recipes are created only by an actual successful installation, through the existing signing engine.

## Validation

54 Swift tests pass: the prior 45 checks plus 9 tests for full workspace restoration, ordered batch import, changed/missing files, exact reviewed snapshots, sequential failure stopping, cancellation, reordering, interruption recovery, removal without deleting IPAs, corrupt/newer state preservation and file permissions. Queue integration tests use a local synthetic signing action, not Apple credentials or device installs.

The installed app is built with Xcode 27.2 / macOS SDK 27.2 and macOS 26 minimum. Packaging preserves the existing signing core, anisette helper, icon assets and approved backdrop. Live UI checks use disposable local IPA fixtures; no real app installation or Apple account mutation is part of verification.
