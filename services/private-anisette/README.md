# Private anisette compatibility candidate

**Status: the user tested the Windows-description candidate and sign-in still
failed. Both candidate containers have been stopped. Port 6969 and the original
server remain unchanged. Do not promote this experiment as a fix.**

The working service the user identified is `https://new.ani.sidestore.io`, which
reports a different `native-c` generator. Rewriting the Android generator's public
description does not turn it into that generator. This directory retains the failed
experiment and its rollback data for diagnosis only.

This builds reviewed source from Dadoum's anisette-v3-server at revision
`684895737aaf1a1c4586fcd5b67509ffd500a36c`. It does not download an unreviewed
server executable or fork image. Official Debian Bookworm images are pinned by
digest, upstream DUB selections are retained, and the compiled image records its
source revision.

APT uses HTTPS. Since Debian Slim initially has no CA store, the build script
fetches a public Mozilla CA bundle from curl's official versioned release and
verifies its pinned SHA-256 before using it to bootstrap normal Debian CA package
installation. TLS verification is never disabled, and no host-specific or private
CA store is copied. The bundle stays in the ignored build context.

The patch has two changes:

1. Change the public V3 client description from the hard-coded macOS description
   to the Windows description in [AhmTb's small compatibility patch](https://github.com/AhmTb/anisette-v3-server/commit/7f8629ed3bf181738ad0b25f025c3950c79aeed1).
2. Stop writing the entire V1 authentication-header response into container logs.

This is a compatibility experiment, not native macOS authentication. ADI still runs
inside Colima and Apple can reject its authentication identity. A listening port,
healthy container, and successful V3 provisioning do not prove Apple accepts a
sign-in. No password or verification code is needed to inspect public metadata.

## Fast candidate using the existing reviewed backend

The network currently downloads Debian/compiler assets very slowly. This variant
uses the already installed, pinned upstream Dadoum image as a backend and the
official, pinned NGINX image as a small V3 frontend:

```sh
python3 services/private-anisette/manage.py proxy-candidate --seed-from anisette
```

Only `/v3/client_info` is replaced with the reviewed Windows JSON. V3 header and
WebSocket provisioning requests are proxied unchanged. The backend is on a separate
Docker bridge with **no published host port**, a separately seeded persistent
volume, and a 30-second provisioning-step timeout instead of upstream's 3 seconds.
The frontend publishes only `127.0.0.1:6970`. V1 routes are blocked, so its raw-header
log route cannot be triggered through this frontend. No unreviewed anisette binary
or fork image is used. Both containers have `unless-stopped` and bounded logs.

This changes two candidate variables (description and provisioning timeout), so a
successful test alone does not establish which was responsible. In particular,
the currently working public provider can advertise the same old Mac description
as the original local server. Treat the Windows description as a test, not an
established cause of rejection. Original port 6969 remains untouched.

## Build and start without replacing the original

Run from the Slip repository:

```sh
python3 services/private-anisette/manage.py build
python3 services/private-anisette/manage.py candidate --seed-from anisette
```

The default Docker context is `colima`; set `SLIP_DOCKER_CONTEXT` explicitly to use
another. Builds use the existing Docker CLI and work without installing Buildx.
The candidate is `slip-anisette-candidate`, bound only to `127.0.0.1:6970`, with a
named persistent volume `slip-anisette-candidate-data`, `unless-stopped` restart
policy, a public-metadata health check, and bounded logs. The original container
and port 6969 remain unchanged. Existing server data is copied through an anonymous
Docker-to-Docker pipe without printing it or creating a host staging copy. An
existing active candidate or an unrecognized volume is never overwritten.

Starting either retained Windows experiment now requires the explicit
`--allow-failed-experiment` flag. This acknowledges its failed user test; it is not
a claim that retrying will repair the underlying generator mismatch.

The healthy Homebrew Colima LaunchAgent is left in place. It starts Colima at user
login; Docker then restarts containers according to their restart policy.

## Validation and later promotion

Read the non-secret public metadata:

```sh
curl --fail --max-time 5 http://127.0.0.1:6970/v3/client_info
docker --context colima inspect slip-anisette-candidate --format '{{.State.Health.Status}}'
```

Only promote a candidate after checking its actual Apple compatibility. Keep the
old container stopped and renamed as a rollback copy rather than deleting it, and
recreate the proven image with a loopback-only mapping on port 6969. Stop the
candidate before reusing its data volume in another server. Do not reset Slip's
account state or revoke developer resources as part of this change.

## Credits and licensing boundary

Upstream server source: [Dadoum/anisette-v3-server](https://github.com/Dadoum/anisette-v3-server).
The source authors and pinned dependency metadata remain in the build. The source
revision inspected here has no LICENSE file or DUB license declaration; this
directory does not assert that the upstream server is MIT-licensed. Slip's existing
MIT and UI license notices remain unchanged. This local build recipe and small
patch are not a grant of redistribution rights for upstream code or Apple's ADI
libraries, which upstream obtains separately from Apple.
