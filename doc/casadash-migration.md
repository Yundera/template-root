# CasaOS → CasaDash migration

Status: **phase 1 implemented**, phases 2–3 outlined.

CasaDash ([worph/CasaDash](https://github.com/worph/CasaDash)) is a dashboard-only
reimagining of CasaOS: the same app grid and the same CasaOS App Store format, in a
single Go binary with an embedded Svelte UI, driving the Docker socket. It has no file
manager, no database, and **no authentication of any kind**.

The migration is staged so that at no point does the PCS depend on the new dashboard
working. Phase 1 makes CasaDash *fully functional alongside* CasaOS without changing who
owns the apps; phase 2 flips the default; phase 3 deletes CasaOS.

---

## Background: how CasaDash finds apps

This is the fact the whole design hangs on, so it is worth stating precisely.
CasaDash has **two** discovery paths (`internal/apps/apps.go`, `Registry.List`):

1. **Managed** — it scans `AppsDir()` = `/DATA/AppData` and treats every subdirectory
   containing a `docker-compose.yml` as an app it owns. Directory name = compose project
   name = tile id. Any directory whose **name contains a dot is ignored**.

2. **Unmanaged** — it lists containers over the Docker socket, groups them by their
   `com.docker.compose.project` label, and for each project with no `AppsDir` folder it
   opens `<com.docker.compose.project.working_dir>/docker-compose.yml` and renders a tile
   **if that file carries an `x-casaos` or `x-compose-app` block**.

Every CasaOS-installed app already satisfies path 2 — its containers carry
`working_dir=/DATA/AppData/casaos/apps/<app>` and its compose has `x-casaos`. **So CasaDash
lists all CasaOS apps the moment it is deployed, with zero file changes.**

What the mirrored files in `/DATA/AppData/<app>/` actually buy is the difference between an
unmanaged and a managed tile:

| | Unmanaged tile | Managed tile |
|---|---|---|
| Open / icon / title / status | ✅ | ✅ |
| Start / Stop / Restart | ✅ (Docker labels) | ✅ (`docker compose up`) |
| Logs / Stats | ✅ | ✅ |
| Settings: Env, Compose, Override, WebUI, Tips | ❌ | ✅ |
| Update (from store) | ❌ | ✅ |

(`AppSettingsModal.svelte` gates the tab set on `managed`: `['logs','stats']` vs the full
list.) Mirroring is therefore about **management capability and migration readiness**, not
visibility.

---

## Phase 1 — cohabitation (implemented)

**Goal**: CasaDash sees and can manage every app; CasaOS stays fully functional and remains
the only installer. Nothing about the running apps changes.

### 1.1 Stack split

The `yundera` stack currently bundles CasaOS. Phase 1 splits it into three so that phase 3
is a deletion rather than surgery:

| Stack | Path | Compose project | Contents |
|---|---|---|---|
| `yundera` | `/DATA/AppData/casaos/apps/yundera` | `yundera` | admin, mesh-router-{tunnel,agent,caddy}, smtp, dex, auth-registrar |
| `casaos` | `/DATA/AppData/casaos` | `casaos` | casaos, casaos-oidc-bridge |
| `casadash` | `/DATA/AppData/casadash` | `casadash` | casadash, casadash-gate (AppShield) |

Both new stacks join the **existing `pcs` network as `external: true`** — the `yundera`
stack still owns and creates it, so the ensure scripts must run after
`ensure-user-compose-stack-up.sh`.

Both directory names are **dotless on purpose**. CasaDash's managed-app scan skips any name
in `/DATA/AppData` containing a dot, so the earlier `.casaos` / `.casadash` paths kept the two
stacks off the grid entirely. We want them visible — the dashboard tiles itself and the CasaOS
stack alongside it — so the dot is gone. `ensure-casa{os,dash}-stack.sh` each `rm -rf` their
legacy dot-directory before deploying; the compose project name is pinned by `name:` inside
the compose file, not by the directory, so the move re-adopts the existing project and
containers rather than creating a second one.

One consequence to keep in mind: `/DATA/AppData/casaos` is *also* CasaOS's own AppData root
(`apps/`, including the `yundera` stack itself, lives underneath it). Deleting the `casaos`
tile from CasaDash would delete every app definition on the PCS. The `casadash` directory has
no such overlap.

**This is the one genuinely mutating step in phase 1.** `ensure-user-compose-stack-up.sh`
runs `docker compose up --remove-orphans` on the `yundera` project; once `casaos` and
`casaos-oidc-bridge` are no longer in that compose file, they are removed as orphans and
then recreated by `ensure-casaos-stack.sh` under the new project. Expect a short CasaOS
outage on the self-check cycle that applies this template. Container names are unchanged
(`casaos`, `casaos-oidc-bridge`), so `DEFAULT_SERVICE_HOST=casaos` and every
`http://casaos:8080` / `http://casaos-oidc-bridge:8090` reference keeps resolving over the
`pcs` network.

Dex's `depends_on: [casaos-oidc-bridge]` is dropped — Compose cannot express a cross-stack
dependency. Both containers `restart: unless-stopped` on a shared network, so this only
affects cold-boot ordering, which Dex tolerates (it retries the connector).

### 1.2 App mirroring

`ensure-casadash-app-mirror.sh` walks `/DATA/AppData/casaos/apps/*` and, for every app
except `yundera`, **copies** `docker-compose.yml` to `/DATA/AppData/<app>/docker-compose.yml`
and generates a `/DATA/AppData/<app>/.env`.

**Copy, not hardlink.** A hardlink was the original proposal and it does not survive contact
with this tree:

- `ensure-casaos-apps-up-to-date.sh` rewrites stale `nip.io` / `sslip.io` Caddy labels with
  `sed -i`, which **replaces the inode**. The link would silently split into two divergent
  files on the first IP change, with no error anywhere.
- CasaDash's *Apply update* does `os.WriteFile(composePath, newBase)`
  (`internal/installer/update.go`), which truncates in place — through a hardlink that would
  **rewrite the CasaOS-side compose too**, destroying the install-time `$AUTH_HASH`
  substitution and the resolved `PUBLIC_IP_DASH` baked into the labels.

The copy is re-derived on **every** self-check, ordered after
`ensure-casaos-apps-up-to-date.sh`, so it always reflects the post-`sed` truth. CasaOS
remains the single writer; the mirror is a downstream projection.

**The `.env` exists so the render can be verified.** CasaOS does not use per-app `.env`
files at all — it interpolates each compose at up-time from the *casaos container's own*
environment (`APP_DOMAIN`, `APP_PUBLIC_IP_DASH`, `PCS_*`, `AppID`, `PUID`/`PGID`/`TZ`, plus
deprecated lowercase V1 vars). The mirror writes exactly that variable set to disk, which
makes the app folder self-contained and — the real point — lets us assert:

```
docker compose --project-directory /DATA/AppData/<app>        config
  ==
docker compose --project-directory /DATA/AppData/casaos/apps/<app> config   # with CasaOS's env
```

The script runs that diff for every app and reports `MIRROR_DRIFT: <app>` on mismatch. If
the two do not render identically, the mirror is wrong and must not be trusted for phase 2.

`COMPOSE_PROJECT_NAME=<app>` is pinned in the mirror's `.env` so the project identity is
independent of the directory name.

**Guards.** A directory under `/DATA/AppData/<app>` usually already exists — it holds the
app's data. That is fine and expected (CasaDash's flat layout puts compose and data in the
same folder). The script only refuses when it finds a `docker-compose.yml` it did not write:
mirrored folders are stamped with a `.casaos-mirror` marker, and a compose file present
*without* that marker is treated as a CasaDash-native app and skipped. A pre-existing `.env`
is backed up to `.env.pre-casadash.bak` once before first overwrite.

### 1.2b Mirroring the `yundera` stack itself

`ensure-casadash-app-mirror.sh` skips `yundera`, so the Settings tile rendered as
**unmanaged** — logs and stats only, no Env / Compose / Override / WebUI tabs. The stack was
always *visible* (its containers carry `working_dir=/DATA/AppData/casaos/apps/yundera` and its
compose carries `x-compose-app`, which is discovery path 2), but that path is two levels below
CasaDash's `AppsDir`, and `isManaged()` is literally
`stat(/DATA/AppData/<project>/docker-compose.yml)`.

`ensure-casadash-yundera-mirror.sh` closes that gap: it copies the stack's compose to
`/DATA/AppData/yundera/docker-compose.yml` and the **unified `.env`** beside it, with the same
`.casaos-mirror` marker and the same copy-not-hardlink rule.

It is a separate script rather than a case inside the app-mirror loop because the two mirrors
have different sources of environment truth. A CasaOS app's `.env` materialises the cocktail
the *casaos container* injects at up-time; this stack is interpolated from the unified `.env`
that `ensure-env-vars-valid.sh` assembles (`DOMAIN`, `PROVIDER_STR`, `DEFAULT_SERVICE_HOST`,
`PUBLIC_IP_DASH`, …). Copying that file wholesale — as `deploy-stack.sh` does — means a
variable added to any source file reaches the mirror with no change to the script.

**No tile is duplicated.** `Registry.List` runs the managed pass first and marks the project
`seen`; the Docker-discovered pass then skips it. The tile only changes character. The folder
name must stay `yundera` — it is joined to the Docker project name by an unvalidated
`projects[name]` lookup, so a divergent name would yield a greyed "stopped" managed tile *plus*
a live unmanaged one.

**The mirror is asserted, not assumed.** The script renders both directories with
`docker compose config` (hermetically, `env -i`, both sides reading only their own `.env`) and
fails on any difference. This matters more here than for an app: a managed tile is one CasaDash
may bring up itself, so a drifting mirror would hand the PCS a different infrastructure spec
than `ensure-user-compose-stack-up.sh` does. Verified byte-identical.

**Accepted, and larger than for an app**: promoting a tile to managed means CasaDash may run
`compose up` on the *PCS infrastructure* — a user pressing Start/Restart, or `Republish()` after
a domain change, brings the stack up from `/DATA/AppData/yundera`, recreating `mesh-router-caddy`
and `dex` among others. `name: yundera` is pinned inside the compose file, so this reconciles
the same project rather than creating a second one, and the render is identical — what it costs
is the working_dir label flipping until the next `ensure-user-compose-stack-up.sh` flips it back.
Container churn, not data loss: the same trade-off §1.3 accepts for every mirrored app, applied
to a more important stack. Note that CasaDash's `Normalize()` rewrites a managed app's compose
before every up; here that only ever touches the mirror copy, which the next self-check
re-derives. Uninstall is not a risk — `yundera` is already in the casadash stack's
`PROTECTED_APPS`.

### 1.3 Deliberate non-goals and accepted risks

- **Nothing is brought up from the mirror.** The mirror scripts write files only. No
  `docker compose up` is ever run from `/DATA/AppData/<app>`.
- **But the mirror is not inert.** `isManaged()` is just `stat(<app>/docker-compose.yml)`, so
  creating the file flips CasaDash's start path from label-based `dx.StartProject` to
  `stackup.Up` from the new directory. If a **user** clicks Start/Restart in CasaDash, Compose
  runs from `/DATA/AppData/<app>` with the same project name, flipping the `working_dir` label;
  the next `ensure-casaos-apps-up-to-date.sh` flips it back. The result is container churn on
  each self-check, not data loss. **Accepted for phase 1** — the resolution is phase 2, where
  CasaOS stops being a writer.
- **CasaOS tiles the auxiliary stacks too — casadash on purpose, casaos as a bare tile.**
  CasaOS's appgrid enumerates every compose project on the box, not just its `apps/` root,
  so both split stacks appear in CasaOS's UI regardless. The casadash stack carries an
  `x-casaos` block so its tile is regular (icon, title, link to the gate); the casaos stack
  deliberately does not — CasaOS must not tile itself inside itself — so it renders as a
  bare project-name tile. Both tiles expose CasaOS's Uninstall action (`is_uncontrolled`
  only hides the store-update action, and CasaOS has no `PROTECTED_APPS` equivalent);
  an uninstall runs `down --volumes` plus working-dir deletion — `/DATA/AppData/casadash`
  is recreated by the next self-check, but `/DATA/AppData/casaos` is the apps root itself.
  In practice that path self-terminates (CasaOS stops its own container mid-uninstall),
  and CasaOS is deleted in phase 3 anyway. Reviewed and **accepted** for phase 1; a
  server-side uninstall guard in casa-img is the fix if this ever needs closing.
- **CasaDash's Uninstall is destructive on unmanaged apps.** `Uninstall` calls
  `dx.RemoveProject(..., RemoveVolumes: true)` *unconditionally and first*, then notices there
  is no app dir and returns success. Reviewed and **accepted**.
- **The launch gate is off.** CasaDash's `internal/server/gate.go` wants Caddy's catch-all;
  `mesh-router-caddy` keeps it (`DEFAULT_SERVICE_HOST`). No configuration change — CasaDash
  simply never receives catch-all traffic.

### 1.4 Access control

CasaDash has **no login**, and it mounts the Docker socket — an exposed port is root on the
host. It is therefore never published: the container only `expose`s 8080 on the `pcs` network,
and the only route in is the **AppShield gate** (`ghcr.io/yundera/appshield`) in the same
stack, which owns the `caddy_*` labels for `casadash-${DOMAIN}` (+ `nip.io` / `sslip.io`
variants). The gate does interactive SSO via `auth-registrar` → Dex → the CasaOS bridge, and
machine auth via `CREDENTIAL_VALIDATE_URL` against the bridge's internal validator.

`AUTH_HASH` is not set: that is a per-app value CasaOS injects at install time, and this stack
is not a CasaOS app. Machine access therefore uses CasaOS credentials, not a shared hash.

### 1.5 Environment

Both new stacks derive their `.env` from the **yundera unified `.env`**, which
`ensure-env-vars-valid.sh` already assembles from `.pcs.env` + `.pcs.secret.env` +
`.ynd.user.env`. The ensure scripts copy that file and append stack-specific values. There is
no second source of truth.

Two CasaDash settings must be right or discovery breaks:

- **`DATA_HOST_PATH` must equal `DATA_ROOT` (`/DATA`).** `metaFor` uses the raw
  `working_dir` label, which holds a *host* path, with no container-path remapping. If the two
  differ, every unmanaged lookup opens a path that does not exist inside the container and
  **no CasaOS app gets a tile**.
- **`APP_NET` must be `pcs`**, not CasaDash's default `mesh` — set in `.env.app` (below), not
  in the stack's `environment:`.

`DOCKER_GID` is computed from `stat -c %g /var/run/docker.sock` at ensure time.

### 1.5b `.env.app` — what an app receives

CasaDash separates the variables it needs to *run* from the variables it *forwards* to the apps
it manages. The first stay in the stack's `environment:` block; the second live in

```
/DATA/AppData/casadash/.env.app
```

which `ensure-casadash-stack.sh` regenerates from the unified `.env` on every self-check, and
writes **before** `deploy-stack.sh` runs — a first-ever install must find it already there.
CasaDash reads it on install and on **every start**, ensuring each key in the app's own `.env` —
so a box that changes domain or public IP carries its apps with it, instead of stranding them on
the deployment they were installed against. See CasaDash's `docs/app-env.md`.

The `REF_*` variables are gone. `REF_PORT` / `REF_SCHEME` / `REF_SEPARATOR` drove CasaOS's
web-UI-URL synthesis, which CasaDash replaced with `x-compose-app`'s `webui-*` fields; `REF_NET`
and `REF_DOMAIN` were duplicates of the `APP_NET` / `APP_DOMAIN` a PCS already sets.

> **One folder for everything CasaDash.** `/DATA/AppData/casadash` holds the deployed stack
> (`docker-compose.yml`, `.env`), the deployment's `.env.app`, *and* CasaDash's own state —
> its `settings.json` and store cache, since `DATA_ROOT/AppData/casadash` is CasaDash's
> `StateDir()`. The old hidden `/DATA/AppData/.casadash` never left staging and is simply
> removed.

> **Version-coupled.** Dropping `REF_*` from the stack requires a CasaDash image that reads
> `.env.app` and keeps its state in the dotless folder. An older image still expects `REF_NET`,
> and would attach apps to no network at all.

### 1.6 Ordering

Appended to `scripts-config.txt`, after the existing update pipeline:

```
ensure-casaos-apps-up-to-date.sh   # existing — does the sed -i label rewrite
ensure-user-compose-pulled.sh      # existing
ensure-user-compose-stack-up.sh    # existing — yundera stack; removes casaos as orphan
ensure-casaos-stack.sh             # NEW — recreates casaos + bridge as their own stack
ensure-casadash-stack.sh           # NEW — casadash + AppShield gate
ensure-casadash-app-mirror.sh      # NEW — mirror compose + .env, verify render equality
ensure-casadash-yundera-mirror.sh  # NEW — same, for the yundera stack (unified .env source)
```

The mirrors run last so they always copy the post-`sed` compose files. The yundera mirror needs
only `ensure-env-vars-valid.sh` (for the unified `.env`) to have run; it sits here to keep the
two mirrors together.

---

## Phase 2 — flip the default (outline)

- Make CasaDash the installer: new apps land in `/DATA/AppData/<app>` and are managed by
  CasaDash directly. CasaOS-installed apps are cut over one at a time by **moving**
  `casaos/apps/<app>` out of CasaOS's `AppsPath` so there is exactly one writer per app; the
  mirror becomes the real thing. This is what removes the working_dir flip-flop from §1.3.
- Stop `ensure-casaos-apps-up-to-date.sh` from touching cut-over apps.
- Point `DEFAULT_SERVICE_HOST` at the AppShield gate so the root domain lands on CasaDash.
- Optionally hand CasaDash the Caddy catch-all so its launch gate works.
- **Implement OIDC directly in the admin app (settings-center-app)** to replace
  `casaos-oidc-bridge` as Dex's identity source. This is the last hard dependency on CasaOS:
  today Dex federates to the bridge, which authenticates against CasaOS's
  `/v1/users/login` + JWKS. Until the admin app owns identity, CasaOS cannot be removed.

## Phase 3 — remove CasaOS (outline)

- Delete the `casaos` stack (`casaos` + `casaos-oidc-bridge`) and its ensure script.
- Delete `ensure-casaos-apps-up-to-date.sh` and `ensure-casadash-app-mirror.sh`.
- Drop the `/DATA/AppData/casaos/apps` tree (keeping `yundera/`, which is where the template
  itself lives — it stays put to avoid rewriting every path in the fleet).
- Remove the `.casaos-mirror` markers.
