# How the PCS auth stack got its shape

Background for the auth scripts under `root/scripts/self-check/`. Nothing here
constrains a future edit — it explains why things that are gone are gone, and
why two or three settings look odd. Script headers keep only the rules that
still bind; the narrative lives here so it can age without rotting a header.

## Dex is a broker, not a credential store

Dex holds no local credential of its own. Interactive login is always federated
to a connector:

- **Local Account** — Authelia, the PCS-local credential store, rendered inline
  by `ensure-dex.sh` and provisioned by `ensure-authelia.sh`.
- **Yundera Login** — the owner's cloud account, federated from the
  orchestrator's OIDC IdP, written as a drop-in by `ensure-yundera-login.sh`.

The old `enablePasswordDB` break-glass admin was removed with the move to
Authelia. The way back into a PCS with no working connector is SSH plus
`tools/authelia-user-manager.sh claim <username>`, which is why
`ensure-support-key.sh` runs as early as its dependencies allow.

## The retired `casaos` connector

Dex used to carry a third connector, `casaos`, federated to
`casaos-oidc-bridge`, which consumed a `BRIDGE_SECRET`. Authelia replaced
CasaOS as the local credential and the bridge died with it. The stale
`BRIDGE_SECRET` and `/DATA/AppData/yundera/casaos-oidc-bridge` were swept off
the fleet by a one-shot migration, retired 2026-09-08 (see
`root/scripts/migrations/README.md`). CasaOS itself was removed in phase 3
(2026-08-02); Maison replaced it, and `stacks/casaos/` and
`ensure-casaos-stack.sh` went with it.

The connector id `casaos` is not reused. Neither is `authelia` or `yundera` —
Dex refuses to start on a duplicate connector id.

## Why Dex has a session at all

Dex v2.45.1 held no browser session: it re-ran its connector on every
`/authorize` and advertised no logout of any kind. That is why the PCS grew a
connector-stickiness hack in `root/caddy/Caddyfile`, and why "log out" could not
actually log anyone out.

Upstream fixed it — RP-Initiated Logout (dex PR #4674) and Back-Channel Logout
with a `sid` claim (PR #4945). With `DEX_SESSIONS_ENABLED=true` Dex keeps a real
`dex_session` cookie and advertises `end_session_endpoint` and
`backchannel_logout_supported`, which is what lets one logout end every app's
session through the spec instead of through bespoke plumbing.

That cookie is what `DEX_SESSION_KEY` encrypts (`ensure-dex.sh` mints it).
Rotating the key invalidates every live Dex session — one round of re-logins,
safe at any time.

## The root move

The template root moved from `/DATA/AppData/casaos/apps/yundera/` to
`/DATA/AppData/yundera/` on 2026-09-08 — see `root-migration.md`. The last
compatibility shim, the legacy-root relocation in `scripts/pcs-init.sh`, was
retired 2026-09-15 once every orchestrator deployment staged at the new root
(staging 2026-09-08, production 2026-09-14). A box restored from a pre-move
backup is the only way back to the old layout, and it needs the whole tree
restored with it, marker directory included.

## The back-channel hairpin

Diagnosed on demostaging2, 2026-09-15. Every login on the box 502'd at
`/nhl-auth/oidc/callback`, with AppShield logging
`code exchange failed: oauth2: cannot parse json: unexpected end of JSON input`.

The cause was not on the box. A PCS component that reaches another PCS component
through its **public** hostname does not stay on the machine: the request goes
out to Cloudflare, through the `mesh-router-gateway-cf` Worker, and re-enters the
same host as `<app>-<ip-dashed>.nip.io`. That day one Cloudflare colo answered
~70% of requests to `auth-<domain>` with an HTTP 200 and an **empty body** —
responses carrying the Worker's `X-Request-ID` but no `via: 1.1 Caddy`, i.e. they
never reached the PCS at all. The failure was vantage-dependent: the origin
answered every direct request correctly and other colos were clean. The broken
one was the colo the PCS's own egress used, so it was invisible from everywhere
except the machine living with it.

**Why the public hostname is used at all.** For an OIDC issuer the string is not
an address, it is an identity — simultaneously the discovery URL, the `iss` of
every signed token, and the URL the browser must visit. It cannot be swapped for
a container name, and it cannot be downgraded to `http://` either: the scheme is
part of the issuer, and a client rejects a discovery document whose `issuer` does
not match the URL it fetched.

**The fix** keeps the string and moves only the lookup — `extra_hosts` pinning
the name to `host-gateway`, plus `SSL_CERT_DIR=/ca` and a read-only mount of
`data/ca`, because on-box TLS terminates at our own Caddy on the mesh-router CA
where the public path had Cloudflare's publicly-trusted certificate.
`mesh-router-agent` writes that CA via `CA_CERT_PATH`, into a directory of its
own so a gate can mount the CA without also mounting `key.pem`.

Shipped for the `admin`, `maison` and `kopia` AppShield gates in `b7f2984`, and
for the Dex → Authelia connector afterwards. The Dex one is gated by a probe in
`ensure-dex.sh`: the connector is only rendered once the CA exists and discovery
actually answers over the pinned path, because a connector Dex cannot open is
dropped at startup and stays dropped until the next restart.

**The rule this leaves behind:** a PCS component must never reach another PCS
component through its public hostname. Public hostnames are for browsers. On-box
callers use the container name — `dex-grpc:5557`, `http://auth-registrar:9092`
and Dex's own back-channel logout calls to `http://<gate>/nhl-auth/...` all
already do. Only where the public hostname is load-bearing identity does the pin
apply, and then the agent's CA change must reach a box **before** the pin does,
or a working call becomes `x509: certificate signed by unknown authority`.

Still open: ~37 store apps run the same AppShield gate and still hairpin.
Shipping the mesh CA into third-party images is the wrong fix — the certificate
is public, but adding a root to a container's trust store lets whoever holds that
CA impersonate any host to it. The right one is an AppShield option for an
internal back-channel base URL that preserves the public issuer identity, which
would retire the pin and the CA mount from the first-party gates as well.
