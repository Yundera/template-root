# Running the stock mesh template on a Yundera PCS

Status (2026-10-01): **preparation and alignment are done and live on the test boxes; the
switch itself has not started.** This template still ships and runs its own copies of the
mesh, auth, Maison and Terminal stacks. What changed is that the two templates now agree on
layout, names and inputs, so the switch is a swap of scripts rather than a migration of state.

"The mesh template" below is `Yundera/mesh-router-template-root`, the FOSS `install.sh`
product behind nsl.sh; "this template" is `Yundera/template-root`. The mesh-side record of
the same work is its `doc/alignment-with-template-root.md`.

## The idea

This template carries its own copies of everything the mesh template does: the mesh stack,
the auth stack (Dex, Authelia, registrar, auth-console), Maison, Terminal, and the scripts
that render and deploy them. The two trees were ported back and forth by hand and drifted in
both directions.

The target is to **ship the mesh template unmodified** on every PCS and reduce this template
to what is genuinely Yundera: preparing the VM, talking to the control plane, and the stacks
only Yundera has. The Yundera self-check becomes a **strict addition** over the mesh one.

"Strict addition" is meant literally, and is testable:

1. The mesh tree on a PCS diffs empty against upstream at the revision it tracks.
2. This template never edits a file the mesh template wrote. It only
   - writes **inputs** the mesh template reads (keys in its `.env`, drop-in files),
   - runs **before or after** it,
   - adds **its own stacks** beside it.
3. Remove the Yundera layer and what is left is a working FOSS box.

Yundera Login already works this way: `ensure-yundera-login.sh` writes
`dex/connectors.d/yundera.yaml`, and `ensure-dex.sh` concatenates whatever it finds there.

## Decisions

| Topic | Decision |
|---|---|
| Schedules | **Two independent crons**, one per template. They touch disjoint compose projects and folders. Stagger them; both default to 03:00. |
| Updates | **Each template updates its own folder from its own channel.** A mesh release reaches the fleet without a Yundera release, so the Yundera layer may depend only on the contract below, and the mesh `stable` branch becomes a fleet-facing release. |
| Generic behaviour | Lives in the mesh template, **in its best version**. The Yundera copy is deleted, not kept in step. |
| Yundera-only values | **`.env` keys in the mesh template**, each defaulting to that template's own behaviour. No forked compose file, no override file. |
| State layout | Each stack's state in the folder named after the stack, on both templates. |
| Auth network | `dex-internal`, on both. |
| Cross-stack contracts | By container name on `pcs`, or by a key in the `.env` — **never a host path into another stack's folder.** The gates reach Dex through the registrar's `internal_issuer_url` (AppShield 3.1); only Dex, which is not ours to change, still mounts the mesh CA. |
| First install on a fresh VM | The mesh **`install.sh` from jsDelivr**, run by this template during provisioning. |
| A create whose mesh run fails | **The create fails.** That includes the mesh self-check's check-only steps (root domain reachable, route registered): a PCS whose mesh is not operational is not a PCS. |
| Mesh Console's update panel on a PCS | **Neither hidden nor locked.** In the end a PCS follows a pure nsl.sh stack, and its owner drives the mesh channel like any nsl.sh user. |
| `EMAIL` | On a PCS **the orchestrator's value wins.** How that coexists with the mesh template's own sync is open — see "To brainstorm". |

## Who owns what, after the switch

| | Mesh template (stock) | This template (Yundera layer) |
|---|---|---|
| Folders | `/DATA/AppData/mesh` (compose, `.env`, `scripts/`, `template/`, `data/`), `/DATA/AppData/auth`, `/DATA/AppData/maison`, `/DATA/AppData/terminal` | `/DATA/AppData/yundera`, `/DATA/AppData/kopia` |
| Stacks | `mesh`, `auth`, `maison`, `terminal` | `yundera` (admin, admin-app), `kopia` |
| Config | its own `.env` | `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` → unified `.env` |
| Self-check | its own list, cron entry, lock, log, migrations, markers | its own list, cron entry, lock, log, migrations, markers |
| Updates | its own channel (`UPDATE_URL` in the mesh `.env`) | its own channel (`UPDATE_URL` in `.pcs.env`) |
| Host | Docker (no-op when present), yq, cron, logrotate | pcs/admin users, sshd, swap, apt, support key, IP family, netplan |
| Control plane | none | `OPERATOR_API`, `USER_JWT`, Yundera Login, backup credentials |

## How the two runs relate

- **Install once.** At provisioning (and on a domain or provider change) this template runs
  the mesh `install.sh --yes --provider … --domain … --email … --channel …`, fetched from
  jsDelivr. With `--yes` and no claim flags it leaves the box unclaimed, which is what a PCS
  wants. It runs **synchronously**, and a non-zero exit fails the create.
- **Not every night.** `install.sh` does a full `docker compose down` of the mesh stack on
  every run, deliberately, to apply an identity change cleanly. The nightly Yundera step is an
  *upsert* of the contract keys into the mesh `.env`, nothing more.
- **Trigger, don't wait.** When this template changes something the mesh template reads, it
  calls the mesh script that consumes it right away — `ensure-dex.sh` after writing or
  removing the Yundera Login drop-in, the mesh `self-check.sh` after an identity change.
  Otherwise the change sits for up to a day until the mesh cron.
- **No `@reboot` in the mesh template**, by design. This template keeps its own.

Order on a cold box: Yundera host prep (users, Docker, user data) → mesh `install.sh` →
Yundera post steps (admin stack, backup, kopia, preinstall). Every Yundera gate needs
`auth-registrar`, so the post steps come after the mesh run, not before.

`install.sh` and `install.ps1` sit behind jsDelivr's 12h cache, so a mesh release that changes
the installer needs the purge its README describes before a create picks it up. The tree
itself comes from the branch tarball and is not cached.

## The contract: what Yundera writes, and where

Into `/DATA/AppData/mesh/.env`, by upsert — never by regenerating the file. **This is in
place today**: `ensure-mesh-stack.sh` passes the key list to `tools/deploy-stack.sh`
(`DEPLOY_ENV_KEYS`), which sets those keys and leaves every other line alone.

**Written on every Yundera self-check** — Yundera is the source of truth:

| Key | From | Note |
|---|---|---|
| `PROVIDER_STR`, `DOMAIN` | orchestrator | required by the mesh `ensure-env-valid.sh` |
| `EMAIL` | `.ynd.user.env` | the orchestrator's value wins; see "To brainstorm" |
| `DEFAULT_PWD` | `.pcs.secret.env` | never regenerated — every installed app derives from it |
| `LOCAL_ADMIN_USER` | `.pcs.env` | read by `ensure-authelia.sh` and the user manager |
| `DEFAULT_SERVICE_HOST` / `_PORT` | `.pcs.env` | |
| `AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, `MESH_CONSOLE_ASSERTION_SECRET`, `AUTH_CONSOLE_ASSERTION_SECRET` | `.pcs.secret.env` | sent so they stay **stable across the switch**; afterwards the mesh template owns them and they leave the list |
| `PUBLIC_IP*` | this template's `ensure-public-ip.sh` | until the switch; afterwards the mesh template detects them (`PUBLIC_IP_MODE`) and Yundera reads them back |
| `TERMINAL_ENABLED`, `SMTP_TO`, `APPSTORE_URL`, `OPERATOR_API` | `.pcs.env` | when set |
| `UPDATE_URL`, `SELF_CHECK_CRON` | `.pcs.env` | **until the switch only** — see below |

**Constants** — what a PCS is, in the mesh template's own knobs:

| Key | Value | What it carries |
|---|---|---|
| `DATA_ROOT`, `PUID`, `PGID` | `/DATA`, `1000`, `1000` | |
| `PUBLIC_IP_MODE` | `interface` | the address on a local interface, IPv6 when there is no public IPv4, drop what the backend cannot ping. The mesh default, `egress`, is for a box behind NAT. |
| `TERMINAL_USER` | `admin` | the mesh default is `root` |
| `BRAND_NAME` | `Yundera` | TOTP issuer, reset-mail sender and subject tag |
| `DEX_THEME_SRC` | `/DATA/AppData/yundera/template/dex-theme` | the login theme — `dex-theme/` therefore stays in this tree |
| `PLATFORM_PROJECTS` | `mesh,auth,yundera,maison,kopia,terminal` | Mesh Console's Stack page |
| `TRUSTED_PUBKEY_HOST_SUFFIXES` | `yundera.com` | with `OPERATOR_API`, the support-key tag on auth-console |
| `BACKUP_ENGINE_CONTAINER` | `kopia-engine` | Maison's resident backup engine |

**Set once, at install, then the mesh stack's own** — because the update panel is neither
hidden nor locked, the owner may change these and a nightly upsert must not put them back:

| Key | Initial value |
|---|---|
| `UPDATE_URL` | the **mesh** channel for the environment (a `.tar.gz`; staging tracks `main`, prod `stable`) |
| `MESH_AUTO_UPDATE` | `true`. "Freeze platform updates" writes it once when toggled, to freeze the mesh too. |
| `SELF_CHECK_CRON` | staggered against this template's own schedule |

Today `UPDATE_URL` and `SELF_CHECK_CRON` are still upserted nightly with **this** template's
values, because Mesh Console reads them from that file and until the switch they are this
template's. At the switch they move to this last group and take the mesh values.

**Files:** `auth/dex/connectors.d/yundera.yaml` (Yundera Login) and `maison/onboarding.json`
(the onboarding gate).

The two templates use `UPDATE_URL` and `SELF_CHECK_CRON` for different things. That only
looked like a collision while one `.env` was a copy of the other.

## What happens to each Yundera script

| Script | Fate at the switch |
|---|---|
| `ensure-mesh-stack.sh`, `ensure-auth-stack.sh`, `ensure-authelia.sh`, `ensure-dex.sh`, `ensure-maison-stack.sh`, `ensure-terminal-stack.sh` | **deleted** — the mesh template's run |
| `ensure-public-ip.sh` | **deleted**; its netplan / `ens19` part stays as a small host step that runs before the mesh self-check |
| `tools/authelia-user-manager.sh`, `set-default-app.sh`, `provision-dex-frontend.sh` | **thin wrappers** that `exec` the mesh copy — settings-center-app, the orchestrator's `support.ts` and `demo` call them by path |
| `tools/onboarding.sh` | stays (Yundera's onboarding state), calling the mesh user manager |
| `ensure-yundera-login.sh` | stays; ends by calling the mesh `ensure-dex.sh` |
| `ensure-maison-stack.sh`'s onboarding gate | becomes a step that only writes `onboarding.json` |
| `stacks/{mesh,auth,maison,terminal}`, `caddy/`, `auth/`, `dex.config.yaml.tmpl` | **deleted** from this tree |
| `dex-theme/` | **stays** — it is the source `DEX_THEME_SRC` points at |
| `library/stacks.sh`, `tools/deploy-stack.sh` | kept for `kopia` and `yundera`, plus the mesh `.env` upsert |
| new: `ensure-mesh-installed.sh` | install once, then upsert the contract keys |
| everything host- and control-plane-related | unchanged |

## The mesh self-check on a PCS, step by step

| Mesh step | On a PCS |
|---|---|
| scripts-executable, logrotate, yq, docker | fine; no-ops after the Yundera host steps |
| `ensure-nightly-self-check` | its own cron entry |
| `ensure-env-valid` | fine: the contract keys are in |
| `ensure-template-sync` | updates the mesh folder from the mesh channel; independent of this template's sync |
| `ensure-public-ip` | the mesh version, in `interface` mode |
| `ensure-email-synced` | writes `EMAIL` from the mesh backend — the open point below |
| `ensure-authelia`, `ensure-dex-session-key`, `ensure-dex` | the mesh version; branding and theme come from the `.env` keys |
| stack pulled / up, `ensure-auth-stack` | stock compose |
| `ensure-maison-stack` | stock; backup engine and onboarding gate come from Yundera inputs |
| `ensure-terminal-stack` | stock; the compose files are identical |
| `ensure-root-domain`, `ensure-route-registered` | check-only, and new for a PCS. A failure during a create fails the create (decided). |

## Done (2026-10-01)

All of it is committed, and verified on holyhorse and wisera (this template) and on
watch.nsl.sh (the mesh template).

- **State layout.** Both templates keep `mesh/data`, `auth/authelia` and `auth/dex` (the
  rendered login theme inside it). This template moved by migration; the mesh template moved
  by migration and, because a box with `MESH_AUTO_UPDATE=false` never runs migrations, from
  the scripts themselves as well.
- **Names.** Same compose project names, same auth network (`dex-internal`; the old
  `yundera-auth` is swept by `ensure-auth-stack.sh`).
- **On-box OIDC.** AppShield 3.1.1 and mesh-auth 1.1.7 on both: every gate logs
  `back-channel via http://dex:5556`. Dex → Authelia keeps the `host-gateway` pin and the
  mesh CA, which the mesh template now also keeps alone in `mesh/data/ca`.
- **Generic fixes ported into the mesh template.** The self-check runner that re-runs the
  whole list when an update changes it; the Authelia readiness wait and the Dex re-start
  after a recreate; the reachability-probed public IP as `PUBLIC_IP_MODE=interface`, with the
  probe URL taken from `PROVIDER_STR`; the auth-console gate as `65534`; `cpu_shares`.
- **Yundera-only values as `.env` keys** in the mesh template — the constants table above.
- **The `.env` direction.** The mesh `.env` is no longer regenerated; on its first run the
  upsert rebuilt the file from the contract keys alone, which removed `USER_JWT`, the backup
  credentials and the other Yundera-only keys from it. The auth, maison, kopia and terminal
  stacks still get a full copy of the unified `.env`.

## Remaining: the switch

Not started. In order:

1. **Write the Yundera layer.** `ensure-mesh-installed.sh`; the wrappers; Yundera Login
   calling the mesh `ensure-dex.sh`; the onboarding gate reduced to `onboarding.json`; then
   delete the forked scripts and stack folders (table above).
2. **Adopt an existing box**, rehearsed on wisera or holyhorse first. The secrets are already
   in the mesh `.env` and the state is already where the stock compose binds it. Left to
   reconcile:
   - the Caddyfile: a directory mount from `yundera/template/caddy` here, a file at
     `mesh/Caddyfile` there;
   - the two empty `template/` mountpoints this template creates in `mesh/` and `auth/` — the
     first becomes the mesh template's real `template/` tree;
   - `UPDATE_URL`, `MESH_AUTO_UPDATE` and `SELF_CHECK_CRON`, which take the mesh values once
     and leave the nightly list;
   - the Authelia JWKS `key_id` (`yundera-pcs` here, `pcs` there): one key rotation;
   - `install.sh` takes the mesh stack down, so either adopt with the lower-level pieces (lay
     the tree down, run the mesh self-check) or accept one short outage per box.
3. **Provisioning.** Run the mesh `install.sh` inside `pcs-init.sh` / `os-init.sh`,
   synchronously, with the mesh channel for the environment, and fail the create when it
   fails.

## To brainstorm

**`EMAIL`, with two writers.** Decided: on a PCS the orchestrator's value is the one that
counts. Not decided: how. The mesh self-check's `ensure-email-synced.sh` fetches the email
from mesh-router-backend and writes it to the same key, on its own schedule. While both
sources agree nothing happens; when they differ, each run puts its own value back and every
flip recreates the stack. Options seen so far:

- **Agree at the source** — the orchestrator sets the mesh backend's email for the user when
  it provisions or changes it, so the mesh lookup returns the same value and neither template
  needs a rule.
- **A mesh-side knob** — an `.env` key that turns the backend sync off, set by the Yundera
  layer. Generic (any operator-run box wants it) and in the spirit of the other knobs, but one
  more of them.
- **Let the Yundera upsert win nightly** — no change anywhere, and a flapping key whenever the
  two differ.

## Accepted for now

Known, and deliberately not blocking:

- Neither `stable` branch has today's work yet.
- The nsl.sh backend cannot ping any IPv6 address (2026-10-01), so `/probe` reports every
  IPv6 as unreachable and this template's `ensure-public-ip.sh` clears `PUBLIC_IPV6` on every
  box. Harmless while every PCS has its own IPv4. The mesh script sends a control address with
  each probe and ignores the verdict for a family whose control fails; the real fix is in the
  backend.
- Not exercised on a real box: a browser login end to end, a fresh mesh install, the mesh
  runner's full re-run on a release that changes the script list, the Windows install path.
- The Terminal stack is a copy of the store app and follows the store's AppShield pin (3.0.2),
  so its gate still reaches Dex through the public URL.
- `install.ps1` creates its data folders under `AppData/yundera/…` rather than
  `AppData/mesh/…`.
- settings-center-app's Migration and DockerUpdate code is broken by the stack split;
  migration is to move to the mesh side (the mesh template's `doc/migration.md`, design only).
