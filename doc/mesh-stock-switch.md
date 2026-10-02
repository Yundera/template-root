# Running the stock mesh template on a Yundera PCS

Status (2026-10-01): **the switch is written and rehearsed, not yet released.** This
template no longer ships its own mesh, auth, Maison and Terminal stacks: it installs the mesh
template through its `install.sh` and hands it inputs (`self-check/ensure-mesh-installed.sh`,
`library/mesh.sh`). Rehearsed on wisera and holyhorse; staging is next, production needs the
mesh `stable` branch first — see "Rollout".

"The mesh template" below is `Yundera/mesh-router-template-root`, the FOSS `install.sh`
product behind nsl.sh; "this template" is `Yundera/template-root`. The mesh-side record of
the same work is its `doc/alignment-with-template-root.md`.

## The idea

This template used to carry its own copies of everything the mesh template does: the mesh
stack, the auth stack (Dex, Authelia, registrar, auth-console), Maison, Terminal, and the
scripts that render and deploy them. The two trees were ported back and forth by hand and
drifted in both directions.

The target is to **ship the mesh template unmodified** on every PCS and reduce this template
to what is genuinely Yundera: preparing the VM, talking to the control plane, and the stacks
only Yundera has. The Yundera self-check is a **strict addition** over the mesh one.

"Strict addition" is meant literally, and is testable:

1. The mesh tree on a PCS diffs empty against upstream at the revision it tracks.
2. This template never edits a file the mesh template wrote. It only
   - writes **inputs** the mesh template reads (keys in its `.env`, drop-in files),
   - runs **before or after** it,
   - adds **its own stacks** beside it.
3. Remove the Yundera layer and what is left is a working FOSS box.

## Decisions

| Topic | Decision |
|---|---|
| Schedules | **Two independent crons**, one per template: this one at 03:00, the mesh one seeded at 03:30. They touch disjoint compose projects and folders. |
| Updates | **Each template updates its own folder from its own channel.** A mesh release reaches the fleet without a Yundera release, so the Yundera layer depends only on the contract below, and the mesh `stable` branch is a fleet-facing release. |
| Generic behaviour | Lives in the mesh template, **in its best version**. The Yundera copy is deleted, not kept in step. |
| Yundera-only values | **`.env` keys in the mesh template**, each defaulting to that template's own behaviour. No forked compose file, no override file. |
| State layout | Each stack's state in the folder named after the stack, on both templates. |
| Auth network | `dex-internal`, on both. |
| Cross-stack contracts | By container name on `pcs`, or by a key in the `.env` — **never a host path into another stack's folder.** |
| First install on a fresh VM | The mesh **`install.sh` from jsDelivr**, run by this template's self-check during provisioning. |
| Adopting an existing box | **The same `install.sh`** — the recommended update path, made to take the stack down only on an identity change (or `--clean-restart`), so an adoption costs no outage. |
| A create whose mesh run fails | **The create fails.** That includes the mesh self-check's check-only steps (root domain reachable, route registered). |
| Mesh Console's update panel on a PCS | **Neither hidden nor locked.** A PCS follows a pure nsl.sh stack, and its owner drives the mesh channel like any nsl.sh user. |
| `EMAIL` | On a PCS **the orchestrator's value wins**: the mesh knob `EMAIL_SYNC=false` turns its backend lookup off, and the Yundera layer upserts `EMAIL`. |
| auth-console on a PCS | Points at the mesh folder like everywhere else, so its two Yundera-only panels (onboarding status, support key) are gone there. Accepted: both stay in the admin app. |

## Who owns what

| | Mesh template (stock) | This template (Yundera layer) |
|---|---|---|
| Folders | `/DATA/AppData/mesh` (compose, `.env`, `Caddyfile`, `scripts/`, `template/`, `data/`, `log/`), `/DATA/AppData/auth`, `/DATA/AppData/maison`, `/DATA/AppData/terminal` | `/DATA/AppData/yundera`, `/DATA/AppData/kopia` |
| Stacks | `mesh`, `auth`, `maison`, `terminal` | `yundera` (admin, admin-app), `kopia` |
| Config | its own `.env` | `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` → unified `.env` |
| Self-check | its own list, cron entry (`MESH_ROUTER_SELFCHECK`), lock, log (`mesh/log/mesh.log`), migrations, markers | its own list, cron entries, lock, log, migrations, markers |
| Updates | its own channel (`UPDATE_URL` in the mesh `.env`, a `.tar.gz`) | its own channel (`UPDATE_URL` in `.pcs.env`, a `.zip`) |
| Host | Docker (no-op when present), yq, cron, logrotate | pcs/admin users, sshd, swap, apt, support key, IP family, the `ens19` IPv6 interface |
| Control plane | none | `OPERATOR_API`, `USER_JWT`, Yundera Login, backup credentials |

## How the two runs relate

- **Install once.** `ensure-mesh-installed.sh` runs the mesh `install.sh --yes --provider …
  --domain … --email … --update-url …` (fetched from jsDelivr, in a clean environment) when the
  mesh is not installed — a fresh VM, or a box still on this template's former stacks — or when
  `PROVIDER_STR` / `DOMAIN` changed. With `--yes` and no claim flags it leaves a fresh box
  unclaimed. A non-zero exit fails the self-check, and so a create (`PCS_PROVISIONING=1`).
- **Otherwise only inputs.** Every run upserts the contract keys into the mesh `.env`; when one
  changed, it runs the mesh `self-check.sh` right away ("trigger, don't wait").
- **Trigger, don't wait** for drop-ins too: `ensure-connector-yundera.sh` (was `ensure-yundera-login.sh`) runs the mesh
  `ensure-dex.sh` when its connector file changes; `onboarding.sh reset` runs the mesh
  `ensure-authelia.sh` and `ensure-dex.sh`.
- **One lock per template.** A mesh script run from this template goes through `mesh_run`, under
  the mesh self-check's own lock, so it never interleaves with the mesh cron.
- **No `@reboot` in the mesh template**, by design. This template keeps its own.

Order on a cold box: Yundera host prep (users, Docker, user data, backup credentials and
config) → mesh `install.sh` → read-back into the unified `.env` → Yundera Login → admin stack →
kopia → Maison onboarding gate. The backup steps come first so Maison's first boot — inside the
mesh install — finds a connected repository; every Yundera gate needs `auth-registrar`, so the
admin and kopia stacks come after.

`install.sh` sits behind jsDelivr's 12h cache, so a mesh release that changes the installer
needs the purge its README describes before a create picks it up. The tree itself comes from
the branch tarball and is not cached.

## The contract: what Yundera writes, and where

All of it is in `scripts/library/mesh.sh`, applied by `ensure-mesh-installed.sh` on every
self-check, by upsert into `/DATA/AppData/mesh/.env` — never by regenerating the file.

**Every run** — Yundera is the source of truth, taken from its own env files:

| Key | From |
|---|---|
| `EMAIL` | `.ynd.user.env` (with `EMAIL_SYNC=false` below, nothing on the mesh side rewrites it) |
| `DEFAULT_PWD` | `.pcs.secret.env` — never regenerated; every installed app derives from it |
| `TERMINAL_ENABLED`, `SMTP_TO`, `APPSTORE_URL`, `OPERATOR_API` | `.pcs.env`, when set |

`PROVIDER_STR` and `DOMAIN` are Yundera's too, but they are the identity: a change goes through
`install.sh --provider/--domain`, which takes the stack down to apply it cleanly. Upserting
them first would hide the change from the installer.

**Constants** — what a PCS is, in the mesh template's own knobs:

| Key | Value | What it carries |
|---|---|---|
| `DATA_ROOT`, `PUID`, `PGID` | `/DATA`, `1000`, `1000` | |
| `PUBLIC_IP_MODE` | `interface` | the address on a local interface, IPv6 when there is no public IPv4, drop what the backend cannot ping |
| `TERMINAL_USER` | `admin` | the mesh default is `root` |
| `BRAND_NAME` | `Yundera` | TOTP issuer, reset-mail sender and subject tag |
| `DEX_THEME_SRC` | `/DATA/AppData/yundera/template/dex-theme` | the login theme — `dex-theme/` therefore stays in this tree |
| `PLATFORM_PROJECTS` | `mesh,auth,yundera,maison,kopia,terminal` | Mesh Console's Stack page |
| `TRUSTED_PUBKEY_HOST_SUFFIXES` | `yundera.com` | with `OPERATOR_API`, the support-key tag on auth-console |
| `BACKUP_ENGINE_CONTAINER` | `kopia-engine` | Maison's resident backup engine |
| `EMAIL_SYNC` | `false` | the orchestrator's `EMAIL` wins |

**Seed once** — written only when absent, then the mesh stack's own: the owner may change them
from Mesh Console, or the mesh template writes them itself, and a nightly upsert would put
back what they changed.

| Key | Initial value |
|---|---|
| `UPDATE_URL` | the **mesh** channel: `main.tar.gz` when this template follows `main` (staging), else `stable.tar.gz`. Also replaced while it still holds the `.zip` this template upserted before the switch. `MESH_UPDATE_URL` in `.pcs.env` overrides it (tests, forks); `MESH_INSTALLER_URL` overrides the installer. |
| `MESH_AUTO_UPDATE` | `true`; `false` when this template is frozen. "Freeze platform updates" (`feature-platform-updates.sh`) writes it once on each toggle. |
| `SELF_CHECK_CRON` | `30 3 * * *` — after this template's 03:00 |
| `DEFAULT_SERVICE_HOST` / `_PORT` | from `.pcs.env`; Mesh Console's default-app editor owns them afterwards |
| `LOCAL_ADMIN_USER` | from `.pcs.env`; the claim owns it afterwards |
| `AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, `MESH_CONSOLE_ASSERTION_SECRET`, `AUTH_CONSOLE_ASSERTION_SECRET` | from `.pcs.secret.env` when this template minted them before the switch — what keeps them stable across it |

**Read back** — the mesh template owns them; `ensure-env-vars-valid.sh` takes them from the mesh
`.env` into the unified `.env`, over any stale `.pcs.env` copy: `PUBLIC_IP*` (the mesh detects
them), `DEFAULT_SERVICE_HOST` / `_PORT`, `LOCAL_ADMIN_USER`.

**Files:** `auth/dex/connectors.d/yundera.yaml` (Yundera Login) and `maison/onboarding.json`
(the onboarding gate, `ensure-maison-onboarding.sh`).

## What happened to each Yundera script

| Script | Fate |
|---|---|
| `ensure-mesh-stack.sh`, `ensure-auth-stack.sh`, `ensure-authelia.sh`, `ensure-maison-stack.sh`, `ensure-terminal-stack.sh` | **deleted** — the mesh template's run |
| `ensure-dex.sh` | a **wrapper**, not a self-check step: runs the mesh copy under the mesh lock. The demo calls it by path after dropping its open-entry connector. |
| `ensure-public-ip.sh` | **deleted**; its netplan / `ens19` part is `ensure-ipv6-interface.sh`, before the mesh install |
| `tools/authelia-user-manager.sh` | a **wrapper** that `exec`s the mesh copy — the path every runbook names |
| `tools/set-default-app.sh`, `tools/provision-dex-frontend.sh` | **deleted**: nothing calls them any more (Mesh Console calls the mesh copy) |
| `tools/onboarding.sh` | stays (Yundera's onboarding state); claims through the mesh user manager, reads the owner from the mesh `.env`, `reset` runs the mesh `ensure-authelia.sh` / `ensure-dex.sh` |
| `ensure-connector-yundera.sh` (renamed from `ensure-yundera-login.sh` 2026-10-02) | stays; runs the mesh `ensure-dex.sh` when the drop-in changes |
| the onboarding gate of `ensure-maison-stack.sh` | `ensure-maison-onboarding.sh`, which only writes or removes `onboarding.json` |
| `stacks/{mesh,auth,maison,terminal}`, `auth/`, `dex.config.yaml.tmpl`, `library/authelia-ready.sh` | **deleted** |
| `caddy/` | **kept for the transition only.** A box that has not switched runs a Caddy that bind-mounts this directory; the sync would otherwise delete it from under that container in the minutes before the adoption recreates it. Delete once every box has switched. |
| `dex-theme/` | **stays** — `DEX_THEME_SRC` points at it |
| `library/stacks.sh`, `tools/deploy-stack.sh` | kept for `kopia` (copy mode only). The upsert mode moved to `library/mesh.sh`; `adopt_network`, the handover helpers and `restart_if_bound` are gone. |
| new: `ensure-mesh-installed.sh`, `library/mesh.sh` | install once, then the contract |
| everything host- and control-plane-related | unchanged; the two backup scripts moved ahead of the mesh install |

## Adopting a box, as rehearsed

On the tick that ships this template, the self-check's first pass runs the old list and skips
the scripts the sync removed; its second pass runs the new list (`self-check.sh` re-runs the
whole list when a sync changed it), and `ensure-mesh-installed.sh` finds a mesh compose but no
mesh `scripts/` — an adoption:

1. the contract is upserted, including the seed-once keys (the `.zip` channel is replaced);
2. `mesh-console-app` and `auth-console-app` are removed (UIs only), freeing the `template/`
   mountpoints this template's consoles nested into the mesh and auth folders;
3. `install.sh` lays down the mesh tree and runs the mesh self-check — the full migration
   backlog (all no-ops on such a box), Authelia re-rendered with `key_id: 'pcs'` (was
   `yundera-pcs`; same key), Dex with the theme in `themes/mesh`, every stack `up -d` from the
   stock compose. Changed services are recreated in place; tunnel and agent keep running;
4. the empty `auth/template` and the old `themes/yundera` are removed.

Verified on wisera and holyhorse (2026-10-01): mesh self-check 19/19, Yundera self-check clean,
both crons installed, mesh tree identical to the tarball, both connectors on the login page,
Dex → Authelia reaching the Authelia login, a second run recreating no container.

## The mesh self-check on a PCS, step by step

| Mesh step | On a PCS |
|---|---|
| scripts-executable, logrotate, yq, docker | fine; no-ops after the Yundera host steps |
| `ensure-nightly-self-check` | its own cron entry, 03:30 |
| `ensure-env-valid` | fine: the contract keys are in |
| `ensure-template-sync` | updates the mesh folder from the mesh channel; independent of this template's sync |
| `ensure-public-ip` | the mesh version, in `interface` mode |
| `ensure-email-synced` | skipped: `EMAIL_SYNC=false` |
| `ensure-authelia`, `ensure-dex-session-key`, `ensure-dex` | the mesh version; branding and theme come from the `.env` keys |
| stack pulled / up, `ensure-auth-stack` | stock compose |
| `ensure-maison-stack` | stock; backup engine and onboarding gate come from Yundera inputs |
| `ensure-terminal-stack` | stock |
| `ensure-root-domain`, `ensure-route-registered` | check-only. A failure during a create fails the create. |

## Rollout

1. **Staging (next).** Push the mesh template's `main` first (`EMAIL_SYNC`, the identity-gated
   `down`, `@` allowed in a provider string) and purge jsDelivr for `install.sh`; then this
   template's `main`. Every box on `main` — and every new staging create — goes through
   `ensure-mesh-installed.sh` at its next self-check: adoption for the existing ones,
   `install.sh` for a fresh VM. `pcs-init.sh` / `os-init.sh` need no change. wisera and holyhorse
   were rehearsed by hand (`UPDATE_URL=local`, `MESH_UPDATE_URL` / `MESH_INSTALLER_URL` at
   `file://` copies) and must be put back on their channels after the push.
2. **Production.** Needs the mesh `stable` branch to carry the auth stack and these changes,
   then this template's `stable`.
3. **Afterwards.** Delete `caddy/` from this tree.

## Accepted for now

Known, and deliberately not blocking:

- Neither `stable` branch has this work.
- The nsl.sh backend cannot ping any IPv6 address (2026-10-01), so `/probe` reports every
  IPv6 as unreachable. Harmless while every PCS has its own IPv4; the real fix is in the
  backend.
- Not exercised on a real box: a browser login with real credentials, a fresh-VM create through
  `install.sh` (first staging create after the push), the Windows install path.
- The Terminal stack follows the store's AppShield pin (3.0.2), so its gate still reaches Dex
  through the public URL.
- `install.ps1` creates its data folders under `AppData/yundera/…` rather than
  `AppData/mesh/…`.
- settings-center-app's DockerUpdate card was removed (1.4.12). Its Migration code is broken by
  the stack split and is being replaced by the mesh template's `scripts/tools/migrate.sh` (its
  `doc/migration.md`): this template feeds it `MIGRATE_TARGET_SELF_CHECK` / `MIGRATE_HOLD_LOCKS`
  through `library/mesh.sh`, and `self-check.sh` / `self-check-reboot.sh` skip a box the mesh
  marks retired. The admin-app pipeline goes once the orchestrator speaks `migrate.sh`. Its
  `dev/run/bootstrap.sh` still calls scripts this template no longer has.
