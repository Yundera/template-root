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
