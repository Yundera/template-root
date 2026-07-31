# CasaOS → Maison migration

Status: **phase 1 implemented**, phases 2–3 outlined. Phase 2's identity blocker is closed
early — the CasaOS OIDC path is deleted (see "Removed: the CasaOS OIDC path").

Maison ([Yundera/Maison](https://github.com/Yundera/Maison)) is a dashboard-only
reimagining of CasaOS: the same app grid and the same CasaOS App Store format, in a
single Go binary with an embedded Svelte UI, driving the Docker socket. It has no file
manager, no database, and **no authentication of any kind**.

The migration is staged so that at no point does the PCS depend on the new dashboard
working. Phase 1 makes Maison *fully functional alongside* CasaOS without changing who
owns the apps; phase 2 flips the default; phase 3 deletes CasaOS.

---

## Rebrand: CasaDash → Maison (image 1.1.0)

The dashboard was called **CasaDash** through phase 1's first rollout and was renamed to
**Maison** at version 1.1.0. Only names changed — the discovery model, `.env.app` contract
and mirroring design below are unaffected — but the names are load-bearing in several
places at once, so everything moved together:

| | Before | After |
|---|---|---|
| Image | `ghcr.io/worph/casadash:1.0.3` | `ghcr.io/yundera/maison:1.1.0` |
| Repo | `github.com/worph/CasaDash` | `github.com/Yundera/Maison` |
| Stack template | `stacks/casadash/` | `stacks/maison/` |
| Compose project + directory | `casadash` → `/DATA/AppData/casadash` | `maison` → `/DATA/AppData/maison` |
| Containers | `casadash` (gate), `casadash-app` | `maison` (gate), `maison-app` |
| Public host | `casadash-${DOMAIN}` | `maison-${DOMAIN}` |
| Listen address env | `CASADASH_ADDR` | `HTTP_ADDR` (also its default) |
| Ensure scripts | `ensure-casadash-*.sh` | `ensure-maison-*.sh` |

Two consequences on an already-provisioned PCS, both handled in
`ensure-maison-stack.sh`'s legacy-locations block:

- **The old project must be torn down explicitly.** Renaming `name:` means the new project
  cannot adopt the old containers, and `--remove-orphans` only reaches orphans of its *own*
  project — so without an explicit `docker compose down` on `/DATA/AppData/casadash` the old
  `casadash` / `casadash-app` pair would run forever, still holding the `casadash-${DOMAIN}`
  Caddy labels and the Docker socket. Nothing else on the box owns that project.
- **The directory is moved, not recreated.** It is also the dashboard's state directory
  (`settings.json`, store cache), so `mv` preserves the user's dashboard; `deploy-stack.sh`
  then rewrites only `docker-compose.yml` and `.env` inside it.

What is *not* recovered: the public hostname changed, so existing gate sessions (cookies on
`casadash-${DOMAIN}`) are dead and every bookmark to the old host stops resolving. Users log
in once more. The AppShield gate re-registers with the auth-registrar under its new
PTR-attested container name (`maison`), leaving the old `casadash` client registration
behind as a harmless stale entry.

**Expect one noisy self-check cycle per PCS.** This is the first template change that
*removes* entries from `scripts-config.txt` rather than adding them. `self-check.sh` slurps
the config into memory before iterating, so on the cycle that applies this template pass 1 is
still walking the pre-rebrand list while `ensure-template-sync.sh` has already rsynced
(`--delete`) the `ensure-casadash-*.sh` files away — three `Script not found` errors and a
non-zero self-check exit. Pass 2 re-reads the new config and runs the `ensure-maison-*.sh`
entries correctly, so the box converges on that same cycle and every later one is clean.
Fresh provisioning is unaffected: `pcs-init.sh` downloads the new tree before the first
self-check, so its config never lists the old names.

Still on the old name deliberately: the tile icon, which the compose file fetches from
`Yundera/AppStore@main/Apps/CasaDash/icon.png`. That rename belongs to the AppStore repo, and
jsDelivr serves the branch tip — repointing at `Apps/Maison/` before that lands 404s every
tile.

---

## Background: how Maison finds apps

This is the fact the whole design hangs on, so it is worth stating precisely.
Maison has **two** discovery paths (`internal/apps/apps.go`, `Registry.List`):

1. **Managed** — it scans `AppsDir()` = `/DATA/AppData` and treats every subdirectory
   containing a `docker-compose.yml` as an app it owns. Directory name = compose project
   name = tile id. Any directory whose **name contains a dot is ignored**.

2. **Unmanaged** — it lists containers over the Docker socket, groups them by their
   `com.docker.compose.project` label, and for each project with no `AppsDir` folder it
   opens `<com.docker.compose.project.working_dir>/docker-compose.yml` and renders a tile
   **if that file carries an `x-casaos` or `x-compose-app` block**.

Every CasaOS-installed app already satisfies path 2 — its containers carry
`working_dir=/DATA/AppData/casaos/apps/<app>` and its compose has `x-casaos`. **So Maison
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

**Goal**: Maison sees and can manage every app; CasaOS stays fully functional and remains
the only installer. Nothing about the running apps changes.

### 1.1 Stack split

The `yundera` stack currently bundles CasaOS. Phase 1 splits it into three so that phase 3
is a deletion rather than surgery:

| Stack | Path | Compose project | Contents |
|---|---|---|---|
| `yundera` | `/DATA/AppData/casaos/apps/yundera` | `yundera` | admin, mesh-router-{tunnel,agent,caddy}, smtp, dex, auth-registrar |
| `casaos` | `/DATA/AppData/casaos` | `casaos` | casaos (+ casaos-oidc-bridge, since deleted — see "Removed: the CasaOS OIDC path") |
| `maison` | `/DATA/AppData/maison` | `maison` | maison (AppShield gate), maison-app (dashboard) |

Both new stacks join the **existing `pcs` network as `external: true`** — the `yundera`
stack still owns and creates it, so the ensure scripts must run after
`ensure-user-compose-stack-up.sh`.

Both directory names are **dotless on purpose**. Maison's managed-app scan skips any name
in `/DATA/AppData` containing a dot, so the earlier `.casaos` / `.casadash` paths kept the two
stacks off the grid entirely. We want them visible — the dashboard tiles itself and the CasaOS
stack alongside it — so the dot is gone. `ensure-casaos-stack.sh` and `ensure-maison-stack.sh`
each `rm -rf` their legacy dot-directory before deploying; the compose project name is pinned
by `name:` inside the compose file, not by the directory, so the move re-adopts the existing
project and containers rather than creating a second one.

That last sentence is exactly what the rebrand below had to break: renaming the project *is*
renaming `name:`, so the new project cannot re-adopt the old containers and the old ones must
be torn down explicitly.

One consequence to keep in mind: `/DATA/AppData/casaos` is *also* CasaOS's own AppData root
(`apps/`, including the `yundera` stack itself, lives underneath it). Deleting the `casaos`
tile from Maison would delete every app definition on the PCS. The `maison` directory has
no such overlap.

**This is the one genuinely mutating step in phase 1.** `ensure-user-compose-stack-up.sh`
runs `docker compose up --remove-orphans` on the `yundera` project; once `casaos` and
`casaos-oidc-bridge` are no longer in that compose file, they are removed as orphans and
then recreated by `ensure-casaos-stack.sh` under the new project. Expect a short CasaOS
outage on the self-check cycle that applies this template. Container names are unchanged, so
`DEFAULT_SERVICE_HOST=casaos` and every `http://casaos:8080` reference keeps resolving over
the `pcs` network.

Dex's `depends_on: [casaos-oidc-bridge]` was dropped at the split — Compose cannot express a
cross-stack dependency, and Dex retries a connector's back-channel anyway. The bridge has
since been deleted outright; see "Removed: the CasaOS OIDC path".

### 1.2 App mirroring

`ensure-maison-app-mirror.sh` walks `/DATA/AppData/casaos/apps/*` and, for every app
except `yundera`, **copies** `docker-compose.yml` to `/DATA/AppData/<app>/docker-compose.yml`
and generates a `/DATA/AppData/<app>/.env`.

**Copy, not hardlink.** A hardlink was the original proposal and it does not survive contact
with this tree: Maison's *Apply update* does `os.WriteFile(composePath, newBase)`
(`internal/installer/update.go`), which truncates in place — through a hardlink that would
**rewrite the CasaOS-side compose too**, destroying the install-time `$AUTH_HASH`
substitution and the resolved `PUBLIC_IP_DASH` baked into the labels.

The copy is re-derived on **every** self-check. CasaOS remains the single writer; the mirror
is a downstream projection.

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
app's data. That is fine and expected (Maison's flat layout puts compose and data in the
same folder). The script only refuses when it finds a `docker-compose.yml` it did not write:
mirrored folders are stamped with a `.casaos-mirror` marker, and a compose file present
*without* that marker is treated as a Maison-native app and skipped. A pre-existing `.env`
is backed up to `.env.pre-maison.bak` once before first overwrite.

### 1.2b Mirroring the `yundera` stack itself

`ensure-maison-app-mirror.sh` skips `yundera`, so the Settings tile rendered as
**unmanaged** — logs and stats only, no Env / Compose / Override / WebUI tabs. The stack was
always *visible* (its containers carry `working_dir=/DATA/AppData/casaos/apps/yundera` and its
compose carries `x-compose-app`, which is discovery path 2), but that path is two levels below
Maison's `AppsDir`, and `isManaged()` is literally
`stat(/DATA/AppData/<project>/docker-compose.yml)`.

`ensure-maison-yundera-mirror.sh` closes that gap: it copies the stack's compose to
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
fails on any difference. This matters more here than for an app: a managed tile is one Maison
may bring up itself, so a drifting mirror would hand the PCS a different infrastructure spec
than `ensure-user-compose-stack-up.sh` does. Verified byte-identical.

**Accepted, and larger than for an app**: promoting a tile to managed means Maison may run
`compose up` on the *PCS infrastructure* — a user pressing Start/Restart, or `Republish()` after
a domain change, brings the stack up from `/DATA/AppData/yundera`, recreating `mesh-router-caddy`
and `dex` among others. `name: yundera` is pinned inside the compose file, so this reconciles
the same project rather than creating a second one, and the render is identical — what it costs
is the working_dir label flipping until the next `ensure-user-compose-stack-up.sh` flips it back.
Container churn, not data loss: the same trade-off §1.3 accepts for every mirrored app, applied
to a more important stack. Note that Maison's `Normalize()` rewrites a managed app's compose
before every up; here that only ever touches the mirror copy, which the next self-check
re-derives. Uninstall is not a risk — `yundera` is already in the maison stack's
`PROTECTED_APPS`.

### 1.3 Deliberate non-goals and accepted risks

- **Nothing is brought up from the mirror.** The mirror scripts write files only. No
  `docker compose up` is ever run from `/DATA/AppData/<app>`.
- **But the mirror is not inert.** `isManaged()` is just `stat(<app>/docker-compose.yml)`, so
  creating the file flips Maison's start path from label-based `dx.StartProject` to
  `stackup.Up` from the new directory. If a **user** clicks Start/Restart in Maison, Compose
  runs from `/DATA/AppData/<app>` with the same project name, flipping the `working_dir` label.
  Nothing flips it back — `ensure-casaos-apps-up-to-date.sh` used to, and was removed (see
  "Removed: the CasaOS app up-to-date script" below), so the app simply stays on the mirror's
  working_dir until CasaOS next touches it. No churn, no data loss.
- **CasaOS tiles the auxiliary stacks too — maison on purpose, casaos as a bare tile.**
  CasaOS's appgrid enumerates every compose project on the box, not just its `apps/` root,
  so both split stacks appear in CasaOS's UI regardless. The maison stack carries an
  `x-casaos` block so its tile is regular (icon, title, link to the gate); the casaos stack
  deliberately does not — CasaOS must not tile itself inside itself — so it renders as a
  bare project-name tile. Both tiles expose CasaOS's Uninstall action (`is_uncontrolled`
  only hides the store-update action, and CasaOS has no `PROTECTED_APPS` equivalent);
  an uninstall runs `down --volumes` plus working-dir deletion — `/DATA/AppData/maison`
  is recreated by the next self-check, but `/DATA/AppData/casaos` is the apps root itself.
  In practice that path self-terminates (CasaOS stops its own container mid-uninstall),
  and CasaOS is deleted in phase 3 anyway. Reviewed and **accepted** for phase 1; a
  server-side uninstall guard in casa-img is the fix if this ever needs closing.
- **Maison's Uninstall is destructive on unmanaged apps.** `Uninstall` calls
  `dx.RemoveProject(..., RemoveVolumes: true)` *unconditionally and first*, then notices there
  is no app dir and returns success. Reviewed and **accepted**.
- **The launch gate is off.** Maison's `internal/server/gate.go` wants Caddy's catch-all;
  `mesh-router-caddy` keeps it (`DEFAULT_SERVICE_HOST`). No configuration change — Maison
  simply never receives catch-all traffic.

### 1.4 Access control

Maison has **no login**, and it mounts the Docker socket — an exposed port is root on the
host. It is therefore never published: the container only `expose`s 8080 on the `pcs` network,
and the only route in is the **AppShield gate** (`ghcr.io/yundera/appshield`) in the same
stack, which owns the `caddy_*` labels for `maison-${DOMAIN}` (+ `nip.io` / `sslip.io`
variants). The gate does interactive SSO via `auth-registrar` → Dex.

**There is no machine/API auth on this gate** — it is interactive SSO only. `AUTH_HASH` is not
set (that is a per-app value CasaOS injects at install time, and this stack is not a CasaOS
app), and `CREDENTIAL_VALIDATE_URL` was removed in 2026-07: it pointed at
`casaos-oidc-bridge:8090/validate`, and Maison exists to *replace* CasaOS, so depending on it
for login was backwards. If a non-interactive path is ever needed, set
`AUTH_HASH_MODE: "managed"` — the `/DATA/AppData/maison/gate-data:/data` mount already
persists the generated token across recreates.

### 1.5 Environment

Both new stacks derive their `.env` from the **yundera unified `.env`**, which
`ensure-env-vars-valid.sh` already assembles from `.pcs.env` + `.pcs.secret.env` +
`.ynd.user.env`. The ensure scripts copy that file and append stack-specific values. There is
no second source of truth.

Two Maison settings must be right or discovery breaks:

- **`DATA_HOST_PATH` must equal `DATA_ROOT` (`/DATA`).** `metaFor` uses the raw
  `working_dir` label, which holds a *host* path, with no container-path remapping. If the two
  differ, every unmanaged lookup opens a path that does not exist inside the container and
  **no CasaOS app gets a tile**.
- **`APP_NET` must be `pcs`**, not Maison's default `mesh` — set in `.env.app` (below), not
  in the stack's `environment:`.

`DOCKER_GID` is computed from `stat -c %g /var/run/docker.sock` at ensure time.

### 1.5b `.env.app` — what an app receives

Maison separates the variables it needs to *run* from the variables it *forwards* to the apps
it manages. The first stay in the stack's `environment:` block; the second live in

```
/DATA/AppData/maison/.env.app
```

which `ensure-maison-stack.sh` regenerates from the unified `.env` on every self-check, and
writes **before** `deploy-stack.sh` runs — a first-ever install must find it already there.
Maison reads it on install and on **every start**, ensuring each key in the app's own `.env` —
so a box that changes domain or public IP carries its apps with it, instead of stranding them on
the deployment they were installed against. See Maison's `docs/app-env.md`.

The `REF_*` variables are gone. `REF_PORT` / `REF_SCHEME` / `REF_SEPARATOR` drove CasaOS's
web-UI-URL synthesis, which Maison replaced with `x-compose-app`'s `webui-*` fields; `REF_NET`
and `REF_DOMAIN` were duplicates of the `APP_NET` / `APP_DOMAIN` a PCS already sets.

> **One folder for everything Maison.** `/DATA/AppData/maison` holds the deployed stack
> (`docker-compose.yml`, `.env`), the deployment's `.env.app`, *and* Maison's own state —
> its `settings.json` and store cache, since `DATA_ROOT/AppData/maison` is Maison's
> `StateDir()`. The old hidden `/DATA/AppData/.casadash` never left staging and is simply
> removed.

> **Version-coupled.** Dropping `REF_*` from the stack requires a Maison image that reads
> `.env.app` and keeps its state in the dotless folder. An older image still expects `REF_NET`,
> and would attach apps to no network at all.

### 1.6 Ordering

Appended to `scripts-config.txt`, after the existing update pipeline:

```
ensure-user-compose-pulled.sh      # existing
ensure-user-compose-stack-up.sh    # existing — yundera stack; removes casaos as orphan
ensure-casaos-stack.sh             # NEW — recreates casaos as its own stack
ensure-maison-stack.sh             # NEW — maison + AppShield gate
ensure-maison-app-mirror.sh        # NEW — mirror compose + .env, verify render equality
ensure-maison-yundera-mirror.sh    # NEW — same, for the yundera stack (unified .env source)
```

The mirrors run last so they always copy the current compose files. The yundera mirror needs
only `ensure-env-vars-valid.sh` (for the unified `.env`) to have run; it sits here to keep the
two mirrors together.

---

## Removed: the CasaOS app up-to-date script

`ensure-casaos-apps-up-to-date.sh` was deleted ahead of phase 2. It walked
`/DATA/AppData/casaos/apps/*` on every self-check and did four things; each is either
obsoleted by Maison or deliberately given up:

| What it did | Status after removal |
|---|---|
| `docker compose up -d` per app with CasaOS's injected env, gated on "≥1 container already running" | **Gone.** Nothing in the self-check chain re-ups user apps. They run under Docker's own `restart:` policy, so reboots are unaffected; what stops is the automatic re-injection of a changed `DOMAIN` / `PUBLIC_IP` / `DEFAULT_PWD` into already-created containers. Maison's `.env.app` (read on every start) is the replacement, and covers an app once it is Maison-managed. |
| `sed -i` repair of stale `<app>-<old-ip-dash>.nip.io` / `.sslip.io` caddy labels | **Gone, deliberately.** No other script in the tree owns this. After an IP change a CasaOS-installed app keeps labels pointing at the previous address — caddy-docker-proxy registers a dead vhost and the real IP subdomain falls through to the catch-all — until the user reinstalls or restarts the app from CasaOS. The mirror copies the stale labels verbatim. The real fix is install-time no longer resolving `${PUBLIC_IP_DASH}`. |
| The `FORCE_START=1` entry point used by the migration pipeline's `start_user_apps` step | **Broken, known.** `startUserApps.ts` still shells out to the deleted path, so the step throws and the migration rolls back. Must be re-pointed at a Maison-side bring-up (the mirrored `/DATA/AppData/<app>/` folders already carry a render-verified compose + `.env`) before PCS→PCS migration works again. |
| Non-zero exit on any app that failed to come up, flipping `OVERALL_FAILED` | **Gone.** A box with a broken app image now reports healthy. |

It also removes the working_dir flip-flop described in §1.3: a user pressing Start in Maison
no longer has their containers churned back on the next self-check.

Removal propagates through `ensure-template-sync.sh`'s `rsync --delete`. Expect one noisy
cycle per PCS — `self-check.sh` slurps `scripts-config.txt` before iterating, so pass 1 walks
the pre-removal list and logs `Script not found` with a non-zero exit; pass 2 re-reads the new
config and the box converges on that same cycle. Same mechanism as the CasaDash→Maison rename.

---

## Removed: the CasaOS OIDC path

Dex's `casaos` connector and the `casaos-oidc-bridge` service are gone. This was written up
as phase 2's hardest item — "implement OIDC directly in the admin app to replace the bridge,
the last hard dependency on CasaOS" — and it turned out to need no implementation at all: the
replacement had already landed. Authelia has been Dex's **Local Account** connector since
2026-07, seeded from the same `DEFAULT_USER` / `DEFAULT_PWD`, with its own password reset and
rate limiting. Keeping the CasaOS connector alongside it meant two local identities for one
person, one of which authenticated against a service scheduled for deletion.

What changed:

| | Before | After |
|---|---|---|
| Dex connectors | Local Account (Authelia), CasaOS, *Yundera Login* | Local Account (Authelia), *Yundera Login* |
| `casaos` stack | `casaos` + `casaos-oidc-bridge` | `casaos` |
| Secrets | `BRIDGE_SECRET` in `.pcs.secret.env` + `.env` | — |
| Hosts | `casaos-oidc-${DOMAIN}` (+ nip.io / sslip.io) | — |

*Yundera Login* is italicised because it is conditional: `ensure-dex.sh` appends it only when
the box has a `YUNDERA_API` and a `USER_JWT`, so a FOSS / test PCS has **Authelia as its only
connector**. That is the real reason this was safe to do now and not before.

Consequences, in the order they will be noticed:

- **The "CasaOS" button disappears from the Dex login page.** Anyone mid-session stays logged
  in (Dex's sqlite keeps the grant), but the next login is Local Account.
- **A diverged CasaOS password does not carry over.** Authelia was seeded once from
  `DEFAULT_PWD`; a user who later changed their password *in CasaOS* changed it only there.
  Their Local Account password is still the original `DEFAULT_PWD` — recoverable from
  `.pcs.secret.env`, or resettable from Authelia's own login page.
- **Apps that key users on the OIDC subject may see a new user.** Dex derives `sub` per
  connector, and the two connectors also differ in `userNameKey` (`name` for the bridge,
  `preferred_username` for Authelia). An app that provisioned an account off the CasaOS
  identity will treat the Authelia identity as a different person. In practice the PCS is
  single-owner and most apps map on email, but check anything with per-user state.
- **CasaOS's own login is untouched.** It still has its user database and its own UI; it is
  simply no longer an identity source for anything else on the PCS.

`ensure-casaos-stack.sh` ups the project with `--remove-orphans`, so the bridge container is
torn down on the cycle that applies this template. `scripts/migrations/2026-07-31-15-drop-casaos-oidc.sh`
sweeps `BRIDGE_SECRET` and `/DATA/AppData/yundera/casaos-oidc-bridge/`.

**What this unblocks.** Phase 3's blocker was identity, and identity no longer lives in
CasaOS. Deleting the `casaos` stack is now a routing-and-installer question, not an auth one.

---

## Phase 2 — flip the default (outline)

- Make Maison the installer: new apps land in `/DATA/AppData/<app>` and are managed by
  Maison directly. CasaOS-installed apps are cut over one at a time by **moving**
  `casaos/apps/<app>` out of CasaOS's `AppsPath` so there is exactly one writer per app; the
  mirror becomes the real thing.
- **Re-point the migration pipeline's `start_user_apps` step** at the mirrored folders — it
  still calls the deleted `ensure-casaos-apps-up-to-date.sh` and rolls migrations back today.
- Point `DEFAULT_SERVICE_HOST` at the AppShield gate so the root domain lands on Maison.
- Optionally hand Maison the Caddy catch-all so its launch gate works.
- ~~Implement OIDC directly in the admin app to replace `casaos-oidc-bridge`~~ — **done, and
  not the way this outline expected.** See "Removed: the CasaOS OIDC path" below.

## Phase 3 — remove CasaOS (outline)

- Delete the `casaos` stack (now just `casaos`) and its ensure script.
- Delete `ensure-maison-app-mirror.sh` (`ensure-casaos-apps-up-to-date.sh` is already gone).
- Drop the `/DATA/AppData/casaos/apps` tree (keeping `yundera/`, which is where the template
  itself lives — it stays put to avoid rewriting every path in the fleet).
- Remove the `.casaos-mirror` markers.
