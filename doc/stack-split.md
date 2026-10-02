# Splitting the `yundera` stack into Maison app folders

Status: **partly implemented, in a coarser shape** (2026-09-30). The services are split into
three stacks, matching mesh-router-template-root rather than the five folders below:

| Stack | Services | Here called |
|---|---|---|
| `mesh` → `/DATA/AppData/mesh` | mesh-router-tunnel, -agent, -caddy, smtp | `router` + `nsl-provider`, not separated |
| `auth` → `/DATA/AppData/auth` | dex, authelia, auth-registrar, auth-console (gate + app: the Account and Access panels) | `accounts` |
| `yundera` → `/DATA/AppData/yundera` | admin, admin-app (Account and Access moved to auth-console) | `yundera` |

Deployed from `template/stacks/{mesh,auth}` by the rsync/self-check path, **not** the store
model of "Two update mechanisms collide" below. The live-box handover of the containers is in
`library/stacks.sh`; `CLAUDE.md` ("Runtime update sequence") has the mechanics.

**The state moved too (2026-10-01).** Each stack's persisted data is in the folder named after
the stack — see "Where the state is now" directly below. Everything after that section is the
original proposal, kept for its reasoning: its "What is on disk today" is the layout *before*
any of this, and its per-app tables use the proposal's folder names (`accounts`, `router`,
`nsl-provider`), not the ones that shipped.

## Where the state is now

```
/DATA/AppData/
├── mesh/                          project "mesh"
│   ├── docker-compose.yml .env .icon.png   written by deploy-stack.sh on every self-check
│   ├── data/
│   │   ├── certs/                 mesh certificate + key   (agent writes, Caddy reads :ro)
│   │   ├── ca/                    the mesh CA alone        (agent writes; dex + every gate :ro)
│   │   └── caddy/{data,config}    Caddy's own state
│   ├── mesh-console/gate-data/    the console gate's sessions
│   └── template/                  EMPTY — mountpoint for the console's template mount
├── auth/                          project "auth"
│   ├── docker-compose.yml .env .icon.svg   written by deploy-stack.sh on every self-check
│   ├── authelia/                  users_database.yml, db.sqlite, configuration.yml, secrets/, oidc/
│   ├── dex/                       dex.db, config.yaml, connectors.d/, frontend/
│   ├── auth-console/gate-data/    the console gate's sessions
│   └── template/                  EMPTY — mountpoint for the console's template mount
└── yundera/                       project "yundera" (admin, admin-app) + the host layer
    ├── docker-compose.yml .icon.svg
    ├── .pcs.env .pcs.secret.env .ynd.user.env   provisioning input
    ├── .env                       their union; the source of every stack's .env
    ├── template/                  the synced tree — the only thing `rsync --delete` touches
    ├── admin/                     admin-app's /app/data; admin/gate-data = the gate's sessions
    ├── log/  migration-markers/  onboarding/  (onboarding.d/)

docker volume  mesh_smtp-data      mail delivery stats — the only named volume
```

| Was (yundera root) | Is | Owner |
|---|---|---|
| `yundera/data/` | `mesh/data/` | mesh |
| `yundera/auth/` | `auth/authelia/` | auth |
| `yundera/dex/` | `auth/dex/` | auth |

`mesh/data` keeps the mesh template's relative layout (`data/{certs,ca,caddy}`), so the console
and the scripts read the same paths on both templates.

**Who reaches across a stack boundary**, which is the list to shrink:

| Reader | Path | Why |
|---|---|---|
| dex | `mesh/data/ca` `:ro` | on-box TLS to `local-auth-${DOMAIN}` terminates on the mesh CA. The AppShield gates left this list on 2026-10-01: AppShield 3.1 reaches Dex at the registrar's `internal_issuer_url` (`http://dex:5556`) and mounts nothing |
| mesh-router-caddy | `yundera/template/caddy` `:ro` | the Caddyfile is template, not state |
| mesh-console-app | `yundera/template` `:ro`, `yundera/log` `:ro` | template revision, the tools it runs, the self-check log |
| auth-console-app | `yundera/template` `:ro` | which tools exist |
| every stack | its own `.env` | only the keys its compose file interpolates (`library/env.sh`, 2026-10-02) — no longer a copy of the union |

Both consoles used to mount the whole yundera root. They now mount their own stack's folder
read-only, with the template tree nested inside it — hence the empty `template/` directories
above: a mount nested in a read-only mount needs its mountpoint to exist, and Docker cannot
create it. A console knob for the template directory would retire both.

### How a live box gets there

`template/scripts/migrations/2026-10-01-10-move-state-into-stack-folders.sh`. The move is a **rename**
on one filesystem, done while the containers keep running: a bind mount holds the inode, not
the path, so nothing is stopped. It runs inside `ensure-template-sync.sh`, before the rsync
delivers the compose files that bind the new paths; `ensure-mesh-stack.sh` and
`ensure-auth-stack.sh` then recreate the containers there later in the same self-check — on
the same directories.

- **It fails hard.** A non-zero exit aborts the sync, so the box keeps its old tree and old
  compose files, which still agree with where the state is. All three renames or none: every
  pair is checked before anything is touched. It refuses when the old and the
  new path both hold files, or when they are on different filesystems. A new path holding only
  empty directories (`ensure-pcs-user.sh`'s `mkdir -p`) counts as absent.
- **It is not in the pre-subtree shim** (`root/scripts/migrations/`). A box still on that layout
  would cross over without running it, and its stacks would then come up on empty folders.
  Accepted: the whole fleet has crossed over (confirmed 2026-10-01).
- **`restart_if_bound`** (`library/stacks.sh`) covers the window between the rename and the
  deploy: the config-reload restarts in `ensure-authelia.sh` / `ensure-dex.sh` skip a container
  still bound to the old path, because starting it again makes Docker create the missing bind
  source as an empty directory. A host reboot inside that window does exactly that; the deploy
  still lands the stacks on the real state, and what is left is a stray near-empty
  `yundera/{data,auth,dex}` to delete by hand.

`root/.ignore` still lists `/auth/**`, `/dex/` and `/data/`. Only a pre-subtree box's old
whole-root `rsync --delete` reads that file, so with the fleet crossed over the lines are
inert — and stay, like the rest of that file.

Outside this repo, one consumer of the old path: the demo's "Open Entry" connector
(`demo/src/lib/DemoManager.ts`), which now probes `auth/dex` before `yundera/dex`.

### Rolling the state move back

A template that predates the move binds the old paths, and Docker creates them **empty**: the
box comes up unclaimed and on a fresh certificate while the real state sits untouched in the
stack folders. Move it back first:

```bash
Y=/DATA/AppData/yundera
docker rm -f authelia dex mesh-router-caddy mesh-router-agent
mv /DATA/AppData/mesh/data     $Y/data
mv /DATA/AppData/auth/authelia $Y/auth
mv /DATA/AppData/auth/dex      $Y/dex
# then sync the older template and run self-check.sh
```

### Decided

- **`auth/authelia` is not backed up, on purpose.** `view: system` stacks are skipped by the
  nightly backup. A lost password is recovered by Authelia's mail reset; a lost folder drops the
  box back to unclaimed and the owner re-claims. This settles "Scheduled backup skips system
  apps" below for the identity state.
- **Rolling back past the state move is a manual step** (above). Accepted.

### Still open from the proposal

- ~~**Per-stack `.env`** (fan-out).~~ Done 2026-10-02: each stack's `.env` (the yundera one included)
  holds only the keys its own compose file interpolates — `library/env.sh`, derived by grepping the
  compose file, so there is no list to maintain. Leftover keys in the source files on older boxes
  (`PUBLIC_IP*`, `LOCAL_ADMIN_USER`, `DEFAULT_SERVICE_*`, pre-switch secrets) are not pruned; they no
  longer reach any stack.
- **`router` vs `nsl-provider`** are still one `mesh` stack.
- **The store model** for these stacks, and Maison `folders` / `pre_up` hooks in place of the
  `ensure-*` scripts.
- **mesh-router-template-root** has the same two stacks with the state still in its root
  (`/DATA/AppData/mesh/{auth,dex}`); the auth half of this move applies there unchanged.

---

Companion to
[`maison-migration.md`](./maison-migration.md), which took the dashboard from CasaOS to
Maison; this document takes the *platform stack* from one compose project to several,
laid out the way Maison lays out every other app.

> **Written before the root move.** Every `/DATA/AppData/casaos/apps/yundera/` path below is
> now `/DATA/AppData/yundera/` — see [`root-migration.md`](./root-migration.md), shipped
> 2026-09-08. That change already delivered this document's step 3 ("kill the mirror; make
> `/DATA/AppData/yundera/` a real app folder"), so the starting point here is one step
> further along than the text assumes.

---

## Why

Two problems, and only one of them is about size.

**The tab rail.** `settings-center-app` renders 11 panels (`src/app/pages/App.tsx`). That is
a lot of first-level navigation for a box whose owner mostly wants to know their domain
works. Maison's `x-compose-app: {view: system}` now gives platform apps their own grid on
the dashboard, so a panel no longer has to live in *the* admin app to be findable.

**The coupling, which matters more.** One process — and one 31KB `docker-compose.yml` with
nine services — knows about nsl.sh, sslip.io, Caddy, Dex, Authelia, the mail relay, the
operator control plane, and support. Every one of those is a thing a FOSS deployment might
not have, or might want to swap. Today that is expressed as runtime feature flags
(`brand.operator`, `brand.support.enabled`) over a monolith that ships all of it regardless.

The split is not primarily a code-size exercise. The panels total ~4.4k lines and the
backend ~4.9k; that is not a large program. It is a *modularity* exercise.

## The rule

> **A panel ships with the container whose state it edits.**

That single rule is what makes the modularity real rather than declarative. Uninstall
mesh-router and the Domain panel is gone — not because a flag hid it, but because it was
never installed. No dead toggles, no `brand.json` entry to maintain, no panel rendering a
form whose backend returns 500.

It also has a corollary that has to be written down, because it is the failure mode that
would make the split worse than the monolith:

> **An app may only write state owned by its own containers. Cross-app needs go over HTTP.**

Right now every panel shares one process and one `.env`, and that is *implicitly* safe. The
moment two app folders both write `/DATA/AppData/casaos/apps/yundera/.env`, the result is a
distributed monolith with none of the monolith's safety. One owner per file. Everyone else
reads.

---

## What was on disk when this was written

> Historical. The current layout is "Where the state is now" at the top.

Three things, where the model says there should be one.

### Root A — `/DATA/AppData/casaos/apps/yundera/`

The stack definition, and the `rsync -a --delete` target of
`scripts/self-check/ensure-template-sync.sh` (honouring `.ignore`).

| Item | What it is |
|---|---|
| `docker-compose.yml` | 31KB, nine services, two networks |
| `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` (+ `.example`) | provisioning inputs |
| `.env` | auto-generated union of the three, by `ensure-env-vars-valid.sh` |
| `caddy/Caddyfile` | Caddy static config |
| `auth/configuration.yml.tmpl` | Authelia config template |
| `dex.config.yaml.tmpl`, `dex-theme/` | Dex config template + branding |
| `scripts/` | `pcs-init.sh`, `self-check/`, `migrations/`, `tools/`, `library/` |
| `log/yundera.log` | self-check log |
| `migration-markers/` | one-shot migration markers |
| `stacks/maison/docker-compose.yml` | the Maison stack, already split out in phase 1 |
| `icon.svg`, `stacks/*/icon.*` | tile icons, shipped as files so no tile depends on a store CDN; deployed as `<app-dir>/.icon.<ext>` by `scripts/tools/deploy-stack.sh` (step 1b) and `ensure-maison-yundera-mirror.sh` |
| `.ignore` | rsync exclusions |

### Root B — `/DATA/AppData/yundera/`

Runtime state, deliberately **outside** the rsync tree. The compose file documents why at
length: `admin-session-key` was not in `.ignore`, so every template update deleted it and
the next container start minted a new one, signing every user out.

| Item | Owner |
|---|---|
| `admin/gate-data/` | AppShield gate sessions |
| `admin/admin-session-key` | legacy — nothing reads it any more |
| `auth/` — `users_database.yml`, `db.sqlite`, `configuration.yml`, `secrets/`, `clients.d/`, `oidc/`, `.lock`, `*.reset-backup` | Authelia |
| `dex/` — `dex.db`, `config.yaml`, `connectors.d/`, `clients/`, `ca-bundle.crt`, `caddy-root.crt`, `admin-password`, `frontend/` (rendered theme, moved in from the sibling `dex-frontend/` 2026-09-18) | Dex |
| `data/certs/` | written by mesh-router-agent, read `:ro` by mesh-router-caddy |
| `data/caddy/{data,config}` | Caddy state |
| `onboarding/completed` | onboarding marker |
| `perf/data` | mesh-router-perf |
| `.casaos-mirror` | phase-1 legacy |

### The mirror

`/DATA/AppData/yundera/{docker-compose.yml,.env,.icon.svg}` are **copies**, written by
`ensure-maison-yundera-mirror.sh` so that Maison renders the stack as an app
(`maison-migration.md` §1.2b). `.icon.svg` is what the Settings tile draws: for a managed
app Maison prefers `.icon.<ext>` in the app folder over the compose's `icon:` URL, so
promoting the stack to managed is also what lets its icon stop being a CDN fetch. Root B is therefore a data directory *and* a synthetic app
folder at the same time. The split is the moment this stops being a copy and starts being
the real thing.

### Maison's model, for contrast

`maison/docs/app-model.md` is authoritative and explicitly supersedes the
`AppData/casaos/apps/<app>` nesting:

```
/DATA/AppData/<app>/
├── docker-compose.yml            # strict copy from the store — never modified
├── docker-compose.override.yml   # Maison-generated + user edits; carries
│                                 #   x-compose-app.store / store-app-id / generated-routes
├── .env                          # prefilled by Maison on create, then user-editable
└── …                             # app data
```

Maison itself already lives exactly like this at `/DATA/AppData/maison/`.

---

## Target layout

Five app folders and one host layer.

| Folder | Services | Panels | Public host | Present in FOSS |
|---|---|---|---|---|
| `/DATA/AppData/maison/` | `maison`, `maison-app` | System Info, Resources, Health, Storage | `maison-${DOMAIN}` | always |
| `/DATA/AppData/accounts/` | `dex`, `authelia`, `auth-registrar`, gate + app | Account, Access | `accounts-${DOMAIN}` | always |
| `/DATA/AppData/router/` | `mesh-router-caddy`, gate + app | Domain, Certificates | `router-${DOMAIN}` | always |
| `/DATA/AppData/nsl-provider/` | `mesh-router-agent`, `mesh-router-tunnel`, `smtp` | — (contributes to Domain) | headless | **optional / swappable** |
| `/DATA/AppData/yundera/` | `admin`, `admin-app` | Operator, Support, Migration, Onboarding | `admin-${DOMAIN}` | **optional** |
| `/DATA/AppData/casaos/apps/yundera/` | — | — | — | host layer, not an app |

Two panels leave without becoming anything: **Terminal** already exists as a store app, and
**Mail** was never a panel's worth of state — it is `x-compose-app.tips` on the
`nsl-provider` tile.

### Naming is load-bearing

`auth-registrar` derives an app's `client_id` from a PTR lookup of the *caller's* container
name on the `pcs` network, and only ever issues redirect URIs under `<client_id>-<suffix>`.
The folder name is the compose project name is the tile identity is the OIDC client id.

That produces one hard constraint immediately: **the auth admin app cannot be called
`auth`.** Dex already owns `auth-${DOMAIN}` and Authelia owns `local-auth-${DOMAIN}`. Hence
`accounts`. Pick every name once, before any of this is built.

Existing hostnames, for reference: `admin-${DOMAIN}` (settings app), `auth-${DOMAIN}` (Dex),
`local-auth-${DOMAIN}` (Authelia), `maison-${DOMAIN}` (Maison).

---

## Per-app scope and persistent data

### `accounts/` — identity

Everything that decides who someone is. The crown jewels, and the highest-risk move.

| From | To |
|---|---|
| `yundera/auth/` | `accounts/authelia/` |
| `yundera/dex/` (now including `frontend/`) | `accounts/dex/` |
| `casaos/apps/yundera/auth/configuration.yml.tmpl` | `accounts/authelia/configuration.yml.tmpl` |
| `casaos/apps/yundera/dex.config.yaml.tmpl` | `accounts/dex/config.yaml.tmpl` |
| `casaos/apps/yundera/dex-theme/` | `accounts/dex-theme/` |
| `yundera/auth/*.reset-backup` | `accounts/.backups/`, or delete |

Env it owns end-to-end: `AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, `LOCAL_ADMIN_USER`,
`DEFAULT_PWD`. Both halves of every pair are inside this folder — no boundary crossings.

`ensure-dex.sh` and the Authelia template rendering become `x-compose-app.hooks.pre_up`.
The directories Authelia and Dex need before first start become `folders` entries
(`schema_version: 2`); `yundera/auth/secrets/` is root-owned today, so its `user`/`group`
have to be stated rather than defaulted.

`auth-registrar` moves here and becomes this app's **public API** — the contract by which
every other gate on the box obtains a client. That is what keeps the other four folders from
needing to know Dex exists.

### `router/` — routes and certificates

The always-present half of the network layer.

| From | To |
|---|---|
| `casaos/apps/yundera/caddy/Caddyfile` | `router/Caddyfile` |
| `yundera/data/caddy/{data,config}` | `router/caddy/{data,config}` |
| `yundera/data/certs/` | `router/certs/` |

Env: `DOMAIN`, `PUBLIC_IP*`, `DEFAULT_SERVICE_HOST`, `DEFAULT_SERVICE_PORT`.

Panels: **Domain** and **Certificates** — merged, not separate apps. sslip.io, nip.io,
`${DOMAIN}` with the gateway CA, and a future Let's Encrypt-only deployment are the same
panel with different issuers, over state this one service owns.

### `nsl-provider/` — the swappable half

`mesh-router-agent`, `mesh-router-tunnel`, and `smtp`.

Mail belongs here, not in a folder of its own: `mail-gateway` takes
`RELAY_CREDENTIAL: "${PROVIDER_STR}"` and relays through the mesh-router-backend that owns
this PCS's domain — its own comment says "same as the nsl path". It is an nsl.sh service
that happens to speak SMTP.

That gives the cleanest env boundary in the whole split: **`PROVIDER_STR` is read by exactly
three services, and all three are in this folder.** Nothing else on the box consumes it —
the admin app's compose comment records that it was deliberately removed from `admin-app`'s
environment.

| From | To |
|---|---|
| `yundera/perf/data` | `nsl-provider/perf/` |

Env: `PROVIDER_STR`, `USER_JWT`.

**Why this is a separate folder from `router/`:** uninstalling the domain provider must not
take Caddy down, or every route on the box dies with it. This is the swap point — the
contract another provider would implement is small, because env injection already does the
work: *set `DOMAIN`, obtain a certificate into `router/certs/`.*

**The one accepted exception to the ownership rule:** `certs/`. `mesh-router-agent` writes
it and `mesh-router-caddy` mounts it `:ro`. Split them and that becomes shared state.
Tolerated because it is one-directional and one file type — `router` owns the directory and
declares it in `folders`; `nsl-provider` receives a write mount. Written down here precisely
so it stays the only exception.

### `yundera/` — the operator app

Reuse the existing folder. The work is mostly subtraction, because it already has the right
shape.

| Action | Item |
|---|---|
| keeps | `admin/gate-data/`, `onboarding/completed` |
| gains | a **real** `docker-compose.yml` + `docker-compose.override.yml` + `.env` |
| loses | `auth/`, `dex/`, `data/` — moved out |
| deletes | `admin/admin-session-key`, `.casaos-mirror`, and the mirror compose/env |

Panels: **Operator**, **Support**, **Migration**, and whatever onboarding ends up as.

Env: `OPERATOR_API` / `YUNDERA_API`, `YUNDERA_USER_API`, `USER_JWT`, `YND_PROVIDER`,
`ENSURE_SUPPORT_KEY`, `BACKUP_*`, `UID`, `ADMIN_ASSERTION_SECRET`.

`admin` (the AppShield gate) and `admin-app` stay together — `ADMIN_ASSERTION_SECRET` is a
pair secret and both ends are in this folder.

This is the only folder that is *entirely* absent from a FOSS deployment.

### `maison/` — the host view

No data moves. Maison gains the three panels that describe the machine rather than the
platform: **System Info**, **Resources**, **Health**. It already has `SystemStatus` and
`Storage` widgets and already has host access; these are host facts, not Yundera facts.

This step alone takes the rail from 11 to 7 with zero new deployment units.

### Host layer — `/DATA/AppData/casaos/apps/yundera/`

Not everything can be an app folder, and pretending otherwise is where this design would go
wrong. What stays:

| Item | Why it cannot move |
|---|---|
| `scripts/` | `pcs-init.sh` and the `self-check` chain run **before Maison exists** |
| `log/yundera.log` | read by `Health.ts`, `preflight.ts`, `startUserApps.ts`, `targetSelfCheck.ts` |
| `migration-markers/` | host-level one-shot state |
| `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` | provisioning **input** (see below) |
| `.ignore` | rsync exclusions — shrinks to almost nothing |

`stacks/maison/` and the unified `.env` both go away. Rename this directory in your head to
"host layer" so nobody expects it to behave like an app.

---

## Environment: fan-out replaces union

Today `ensure-env-vars-valid.sh` merges three source files into one `.env` that every service
reads from. After the split each app folder has its own `.env`, and the three source files
stay as provisioning **input** that bootstrap *fans out* rather than merges.

Three categories, three different mechanisms:

| Category | Examples | Mechanism |
|---|---|---|
| Deployment facts every app needs | `DOMAIN`, `PUBLIC_IP*`, `PUID`/`PGID`, `TZ`, `REF_*` | **Already solved** — Maison injects these per `.env.app` (`maison-migration.md` §1.5b) |
| Pair secrets | `ADMIN_ASSERTION_SECRET`, `AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY` | Both ends live in one folder — no crossing |
| App-scoped config | `PROVIDER_STR`, `OPERATOR_API`, `LOCAL_ADMIN_USER` | Fanned out to the one folder that reads it |

**`BACKUP_*` is the one genuine crossing.** The operator provisions it (`yundera`) and
Maison's backup engine consumes it. It needs a named owner and an explicit handoff, not a
file both happen to read.

---

## Cross-cutting decisions

### 1. Two update mechanisms collide

`ensure-template-sync.sh` does `rsync -a --delete` over the whole stack directory. Maison
re-fetches `docker-compose.yml` from `x-compose-app.store` / `store-app-id`. These are two
update paths for the same file and one has to win **per app**.

Proposed: the split-out apps (`accounts`, `router`, `nsl-provider`) move to the **store
model** and are published in the AppStore; the host layer keeps rsync.

This permanently retires a bug class rather than merely fixing an instance of it. The
`admin-session-key` incident happened because `rsync --delete` walked over app data that a
`.ignore` entry was supposed to protect. If nothing ever rsyncs over an app folder, no
`.ignore` entry can be forgotten.

### 2. Scheduled backup skips system apps

`x-compose-app.md`: a `view: system` app is **skipped by scheduled backup**, because backing
an app up stops it and taking the gateway down nightly is not a backup strategy.

After the split that exclusion covers `accounts/authelia/users_database.yml`,
`accounts/authelia/db.sqlite`, `accounts/dex/dex.db`, and `router/certs/` — i.e. every
credential on the box. These are small, low-churn, and do not need the app stopped, so a
plain config-copy path alongside the stop-and-snapshot engine is sufficient.

**Decide this before splitting**, because Migration depends on enumerating the same list.

### 3. Boot ordering

One compose project with `depends_on` becomes five projects with none. `router` must be up
before anything is reachable; `accounts` must be up before any gate can validate a session.
Cross-project `depends_on` does not exist.

Either Maison orders the platform apps, or the gates tolerate a cold IdP. Confirm
AppShield's actual retry behaviour before relying on the second.

### 4. Migration gets easier

Worth stating because it cuts the other way from the rest of this list. `MigrationVolumes.ts`
already rsyncs `/DATA` wholesale plus `/var/lib/docker/volumes`. A flat
`/DATA/AppData/<app>/` layout is strictly simpler to enumerate and move than the current
two-roots-plus-mirror arrangement.

### 5. No shared UI package, at least not yet

Resist extracting a component library across the admin apps. It would re-couple exactly what
the split decouples, and Maison being Svelte while the admin apps are Next/React already
forces divergence. Similar by convention, not by dependency.

---

## Onboarding is the open question

Onboarding does not belong to any of the five, and that is the signal rather than a gap in
the design. It *sequences* them: claim the account (`accounts`) → choose a domain (`router`)
→ obtain a certificate (`nsl-provider`) → register with the operator (`yundera`). Put it
inside any one folder and that folder is coupled to all the others again — the monolith,
rebuilt with extra steps.

**Proposed:** onboarding is a first-boot wizard owned by **Maison**, and each platform app
declares its own steps through a small contract:

```
GET /setup/status → { needed: bool, done: bool, title: string, url: string }
```

Maison renders whatever the installed apps declare. No `nsl-provider` installed, no domain
step — automatically, with no conditional anywhere. That is the same payoff the ownership
rule buys everywhere else, applied to the one surface that spans all of them.

**Fallback if that is too much for a first version:** keep onboarding in `yundera` and accept
that a FOSS deployment gets no wizard yet. Legitimate — but decide it deliberately rather
than by default, because it is the difference between a modular platform and a Yundera
platform with optional parts.

`onboarding/completed` moves with whatever decision this is.

---

## Sequencing

Not a big-bang. Each step ships independently and leaves a working system.

| # | Step | New units | Risk | Value |
|---|---|---|---|---|
| 1 | Delete the Terminal panel (the store app already exists) | 0 | none | −1 panel |
| 2 | System Info + Resources + Health → Maison | 0 | low | **rail 11 → 7** |
| 3 | Kill the mirror; make `/DATA/AppData/yundera/` a real app folder | 0 | low | removes the phase-1 hack |
| 4 | Extract `accounts` | +1 | **highest data risk** | the FOSS/enterprise story |
| 5 | Extract `router` + `nsl-provider` (mail folded in) | +2 | **highest availability risk** | the provider swap point |
| 6 | What remains *is* the `yundera` app | 0 | none | no rename needed |

Steps 1–3 are worth doing regardless of whether 4–6 ever happen: they solve "the admin app
is too big" on their own, add no deployment units, and delete two pieces of migration debt.

Step 4 before step 5 deliberately. `accounts` has more data at stake but a cleaner boundary —
every secret it touches has both ends inside the folder. `router`/`nsl-provider` has the
`certs/` handoff and the boot-ordering problem, so it should not also be the step that proves
the pattern.

> Mail was originally scoped as a sixth, trivial folder — zero mounted volumes, a pure-env
> rehearsal of the whole pattern. Folding it into `nsl-provider` is correct (it is an nsl.sh
> service), but it does remove the free rehearsal. If one is wanted, a throwaway
> `x-compose-app`-only app is cheaper than discovering the store-update path for the first
> time on `accounts`.
