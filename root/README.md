# yundera stack

The PCS's own layer on top of the stock mesh template: the **Settings** dashboard
(settings-center-app) behind its AppShield gate, and the host-side scripts that provision
a Yundera PCS and feed the mesh template its inputs. Routing, login, Maison and the
Terminal are **not** here — they are the mesh template's stacks (below).

| Host | Serves |
|---|---|
| `admin-${DOMAIN}` | the `admin` gate → settings-center-app (also the Maison **Settings** tile) |

Also answers on `admin-${PUBLIC_IP_DASH}.nip.io` and `.sslip.io`.

Deployed to `/DATA/AppData/yundera` (project name `yundera`). This README is copied there
by `ensure-template-sync.sh` on every sync, beside the compose file.

## Services

| Container | Image | Networks | Role |
|---|---|---|---|
| `admin` | `appshield` | `pcs` | AppShield gate — the only public route in. Runs as `65534:65534` |
| `admin-app` | `settings-center-app` | `pcs` | The dashboard. SSHes to the host as `admin` for privileged work. No route of its own |

- **Names are load-bearing.** auth-registrar derives a client_id from the *caller's*
  container name (PTR on `pcs`) and only issues redirect URIs under `<name>-<suffix>`.
  The gate must be the container named `admin`; swap the names and the callback lands on a
  host no `caddy_*` label publishes.
- **The app re-checks identity.** `admin-app` is reachable by every container on `pcs`
  and can open a host shell, so it trusts only the gate's signed `X-AppShield-Assertion`
  (`IDENTITY_ASSERTION_SECRET`, audience `admin`), never forwarded `Remote-*` headers.
- **Env is enumerated, not `env_file: .env`.** The app gets the handful of keys it reads
  (`COMPOSE_FOLDER_PATH`, `DOMAIN`, `UID`, `PUBLIC_IP`, `OPERATOR_API`, `SUPPORT_EMAIL`,
  the assertion secret, `UPSTREAM_LOGOUT_URL`). The wholesale `.env` used to carry
  `USER_JWT`, `DEFAULT_PWD`, `PROVIDER_STR` … and the web terminal spreads `process.env`
  into every shell it spawns. Nothing from `.pcs.secret.env` enters the container now.
- **`UPSTREAM_LOGOUT_URL`** points the browser at Authelia's `/api/logout`, so logging out
  of Settings also ends the Local Account session and the next sign-in really prompts.

## How it is built

From `template/scripts/self-check/scripts-config.txt`, the steps that touch this stack (in
order, with unrelated host steps elided):

```
ensure-template-sync.sh       release zip root/template/  → yundera/template/   (rsync --delete)
                              root/docker-compose.yml     → yundera/docker-compose.yml
                              root/icon.svg               → yundera/.icon.svg
                              root/README.md              → yundera/README.md
                              (then runs pending migrations)
ensure-yundera-user-data.sh   ${OPERATOR_API}/user/info   → .ynd.user.env (UID, EMAIL, DOMAIN)
ensure-mesh-installed.sh      install / feed the stock mesh template (see below)
ensure-env-vars-valid.sh      validate + generate .env (keys the compose interpolates only)
ensure-connector-yundera.sh   Yundera Login drop-in (see below)
ensure-user-compose-pulled.sh
ensure-user-compose-stack-up.sh   ADMIN_ASSERTION_SECRET → .stack.env / .env; chown gate-data;
                                  up with backoff
```

### The .env

Three hand-off files written by parties outside this stack, the stack's own state, and one
generated file:

| File | Written by | Holds |
|---|---|---|
| `.pcs.env` | orchestrator at provisioning | `UPDATE_URL`, `OPERATOR_API`, `YUNDERA_LOGIN_ENABLED`, `SELF_CHECK_CRON`, `SMTP_TO`, `SUPPORT_EMAIL` … |
| `.pcs.secret.env` | orchestrator + `ensure-yundera-user-data.sh` | `USER_JWT`, `DEFAULT_PWD`, `PROVIDER_STR` |
| `.ynd.user.env` | `ensure-yundera-user-data.sh` | `UID`, `EMAIL`, `DOMAIN` |
| `.stack.env` | this stack's own scripts (`ensure_secret`, `library/secrets.sh`) | `ADMIN_ASSERTION_SECRET`. Never regenerated; 600 |
| `.env` | `ensure-env-vars-valid.sh` | **generated** — don't edit |

`ensure-env-vars-valid.sh` validates the union (later file wins) and writes `.env` with
**only the keys `docker-compose.yml` interpolates** (`env_emit_for_compose`,
`library/env.sh`), plus the keys the mesh template owns, read back from
`/DATA/AppData/mesh/.env` (public IP, default app, owner name). Mode 600, created empty
before it is filled.

### Two roots: `root/` vs `root/template/`

| Repo path | On the box | Sync |
|---|---|---|
| `root/template/` | `/DATA/AppData/yundera/template/` | `rsync -a --delete` — holds no state, disposable |
| `root/docker-compose.yml`, `icon.svg`, `README.md` | `/DATA/AppData/yundera/` | single files, never `--delete` |

The stack root holds state (env files, `admin/`, `log/`, markers), so `--delete` must never
run over it. That is the whole point of the split — see `doc/template-subtree.md`.

## The mesh template underneath

A PCS runs mesh-router-template-root **unmodified** in `/DATA/AppData/mesh`: the `mesh`,
`auth` and `maison` stacks, with their own self-check (03:30), lock, log,
migrations and update channel. Each has its own README in that repo
(`stacks/<name>/README.md`, and on the box `/DATA/AppData/<name>/README.md`).

This template never edits a file the mesh template wrote. It only writes **inputs** and
runs mesh scripts — the whole contract is `template/scripts/library/mesh.sh`:

- **Every run** (Yundera is the source of truth): `EMAIL DEFAULT_PWD SMTP_TO
  APPSTORE_URL OPERATOR_API`, plus PCS constants (`DATA_ROOT=/DATA`,
  `PUBLIC_IP_MODE=interface`, `BRAND_NAME`, `DEX_THEME_SRC` → this template's
  `dex-theme/`, `PLATFORM_PROJECTS`, `BACKUP_ENGINE_CONTAINER=kopia-engine`, …).
- **Seed once** (then the mesh's own): default app, `LOCAL_ADMIN_USER`, and the secrets
  this template minted before the switch (`AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, …) —
  re-minting them would break every app or log everyone out.
- **Identity** (`PROVIDER_STR`, `DOMAIN`) is never upserted: a change goes through the
  mesh `install.sh`, which takes the mesh stack down to apply it cleanly.

`ensure-mesh-installed.sh` installs it (fresh VM, adoption, identity change) and otherwise
runs the mesh self-check when a key changed ("trigger, don't wait"). **A failed install
fails the self-check, and so a PCS create.** Mesh scripts are always run through
`mesh_run`, which takes the mesh lock (`/var/run/mesh-self-check.lock`) so they never race
the mesh cron.

## Yundera Login connector

Lets the owner sign in with their Yundera cloud account, next to the Local Account. It is
not a stack: `ensure-connector-yundera.sh` writes one Dex connector drop-in into the mesh
template's generic seam, `/DATA/AppData/auth/dex/connectors.d/yundera.yaml`. Dex and the
mesh template know nothing about Yundera.

1. **Wanted?** `YUNDERA_LOGIN_ENABLED` in `.pcs.env` (default on; `0/false/no/off` removes
   it — the demo box, whose owner is the demo service's own account, is why).
2. **Inputs**: `DOMAIN`, `OPERATOR_API`, `USER_JWT`. Any missing → no connector, exit 0.
3. **Register**: `POST ${OPERATOR_API}/auth/pcs-client` with `Bearer USER_JWT` and
   `redirect_uris: [https://auth-${DOMAIN}/callback]` → `client_id`/`client_secret`.
   Idempotent server-side: the same PCS gets the same client back every tick.
4. **Probe**: `GET ${OPERATOR_API}/auth/.well-known/openid-configuration` — exactly the
   request Dex makes at startup.
5. **Write** the drop-in (id `yundera`, `userNameKey: email`, `insecureSkipEmailVerified`
   — owner enforcement is upstream in the IdP's owner policy), owned by uid 1001 like the
   rest of Dex's tree.
6. **Apply**: if the file changed, run the mesh `self-check/ensure-dex.sh` under the mesh
   lock, so the login page changes now, not at the next mesh run.

**Fail-open, always.** The drop-in is cache, not config: on *any* doubt (disabled, no JWT,
registration refused, issuer not answering) the file is **removed** and the script still
exits 0. Login must not depend on the Yundera cloud — and Dex treats an unreachable OIDC
issuer as fatal at startup, so a stale drop-in would take down every login on the box,
Local Account included.

`template/scripts/tools/feature-yundera-login.sh status|enable|disable` flips the flag and
re-runs the script; it prints `{"id","enabled"}`. Careful on an unclaimed box: there is no
Local Account connector yet, so disabling this leaves only the support SSH key.

## On disk

```
/DATA/AppData/yundera/
├── docker-compose.yml  .icon.svg  README.md   from the release, every sync — don't edit
├── .env                                       generated every self-check — don't edit
├── .pcs.env  .pcs.secret.env  .ynd.user.env   SOURCES — the provisioning input
├── .stack.env                                 this stack's own state (ADMIN_ASSERTION_SECRET), 600
├── template/                                  the synced tree (rsync --delete), no state
├── admin/                                     admin-app's /app/data (brand.json overrides)
│   └── gate-data/                             the gate's sessions.json (owned by 65534)
├── log/yundera.log                            self-check log
├── migration-markers/                         applied migrations
└── onboarding/  onboarding.d/                 claim / onboarding state
```

The stale pre-2026-09-08 copy at `/DATA/AppData/casaos/apps/yundera/` is left in place on
purpose; nothing reads it. Never `rm -rf /DATA/AppData/casaos` — it still holds store apps.

## What it needs from the other stacks

- **mesh** — Caddy routes `admin-*`; the `pcs` network (external, created by
  `ensure_pcs_network`).
- **auth** — the gate registers with `auth-registrar` and logs in through Dex; logout calls
  Authelia. So this stack comes up after `ensure-mesh-installed.sh`.
- **Host** — the `admin` sudoer (`ensure-admin-user.sh`): the app writes its fresh pubkey
  into `/home/admin/.ssh/` on every start and does privileged work over `ssh` + `sudo -n`.

## Day-to-day

```bash
sudo bash /DATA/AppData/yundera/template/scripts/self-check.sh       # full run
tail -f /DATA/AppData/yundera/log/yundera.log

# one step
sudo bash /DATA/AppData/yundera/template/scripts/self-check/ensure-connector-yundera.sh
sudo /DATA/AppData/yundera/template/scripts/tools/feature-yundera-login.sh status

# the mesh side
sudo bash /DATA/AppData/mesh/scripts/self-check.sh
cat /DATA/AppData/auth/dex/connectors.d/yundera.yaml
docker logs admin | tail
```

## Known traps

| Symptom | Cause |
|---|---|
| Settings authenticates nobody | `ADMIN_ASSERTION_SECRET` empty in `.env` — `ensure-user-compose-stack-up.sh` mints it before `up` |
| Owner signed out on every gate restart, `[session] save failed: permission denied` | `admin/gate-data` not owned by 65534 — `ensure-user-compose-stack-up.sh` chowns it |
| No "Yundera Login" button | Disabled, missing `USER_JWT`, registration failed or issuer down — the log line from `ensure-connector-yundera.sh` says which |
| Settings tile links to a literal `https://admin-${DOMAIN}/` | Maison read `x-casaos` — it never interpolates; `x-compose-app.webui-host` is the one field it substitutes |
| A value edited in `.env` reverts | `.env` is generated — edit `.pcs.env` / `.pcs.secret.env` / `.ynd.user.env` |
| A hand-placed script under `template/` reverts | The sync rsyncs over it — see `doc/template-subtree.md` |
| PCS create fails at the mesh step | `ensure-mesh-installed.sh` fails hard by design; read the mesh install output in the log |

## See also

- `docker-compose.yml` — the rationale for every setting.
- `template/scripts/library/mesh.sh` — the full mesh contract.
- `doc/mesh-stock-switch.md`, `doc/stack-split.md`, `doc/template-subtree.md`,
  `doc/root-migration.md`, `doc/pcs-onboarding.md`, `doc/auth-history.md`.
- The mesh template's `stacks/auth/README.md` — Dex, connectors and the drop-in contract.
