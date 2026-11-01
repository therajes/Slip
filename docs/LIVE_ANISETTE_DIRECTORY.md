# Live macOS anisette directory

Apple Accounts → Authentication source → Remote compatibility offers a native
server picker. Its source is the public
[SideStore server directory](https://github.com/SideStore/anisette-servers/blob/main/servers.json).
Slip downloads the raw JSON directly from GitHub; it does not depend on a Slip
server, GitHub account or API token. The directory is a discovery source, not the
authentication backend.

Only entries tagged `kind: 2` are displayed. Their array order is preserved;
latency, names and connection results never sort the rows. Duplicate canonical
URLs retain their first occurrence. Unsupported kinds, unsafe URLs and invalid
names are excluded. A future server kind is not guessed from its display name.

Opening the picker revalidates GitHub using `ETag` / `If-None-Match` and
`Cache-Control: no-cache`. It refreshes every 60 seconds while open and the app
is active, on returning to the app, or using Refresh. GitHub's CDN can still
cache its published copy; this is live retrieval, not a push subscription.
Polling stops when the popover closes.

A bounded last-good copy is kept in the user's Caches directory. Cached rows
are identified and remain disabled until GitHub revalidation succeeds, so a
stale list cannot be mistaken for current membership. A refresh error preserves
the last good list and the currently selected provider. A saved/custom provider
remains editable even if it is absent from the directory.

Selecting a listed row revalidates its current membership, then requests only
`GET /v3/client_info` from that server. It must return valid client-info and
user-agent strings and report a macOS identity before the choice is applied.
The pending row shows a small progress indicator. Failure preserves the selected
provider. The check establishes response/metadata compatibility at that moment;
it does not guarantee subsequent availability or acceptance by Apple's login
service. Raw metadata is not retained or logged.

Provider controls are disabled during authentication. An in-progress selection
is cancelled if the popover closes or authentication begins. Refresh never
changes the selected URL. Existing backend provider/session isolation and Apple
sign-in behavior are unchanged. Custom/private endpoints remain available;
external endpoints require HTTPS and HTTP is allowed only for literal loopback.

Networking uses an ephemeral URLSession without cookies or credential storage,
normal TLS verification, no redirects, bounded responses and timeouts. The
catalog is limited to 256 KiB / 500 rows; a metadata response is limited to 16 KiB.
No Apple password, verification code or account session is sent in these
directory or connection-check requests.

Sources: `AnisetteServerDirectory.swift` handles retrieval, cache, URL validation
and preflight. `RemoteAnisetteSettings.swift` presents the existing card's control
and native popover. Tests use synthetic catalog/metadata and a fixture transport;
they never submit Apple credentials or modify developer resources.

The 2026-10-31 release uses public Xcode 27.2 (27B52), macOS SDK 27.2 and a macOS
26 deployment target. The previously selected Xcode beta and its bundled SDKs
were moved to Trash after verifying the public toolchain and first-launch setup.
No backdrop, icon artwork, certificate or developer-account migration is part of
this feature.
