# Running the stock mesh template on a Yundera PCS

Status: **design, plus a first preparation pass** (2026-10-01). The switch itself is not
implemented. "The mesh template" below is `Yundera/mesh-router-template-root`, the FOSS
`install.sh` product behind nsl.sh; "this template" is `Yundera/template-root`.

## The idea

Today this template carries its own copies of everything the mesh template does: the mesh
stack, the auth stack (Dex, Authelia, registrar, auth-console), Maison, Terminal, and the
scripts that render and deploy them. The two trees were ported back and forth by hand and
have drifted in both directions.

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
`dex/connectors.d/yundera.yaml`, and the mesh template's `ensure-dex.sh` concatenates
whatever it finds there.

## Who owns what, after the switch

| | Mesh template (stock) | This template (Yundera layer) |
|---|---|---|
| Folders | `/DATA/AppData/mesh` (compose, `.env`, `scripts/`, `template/`, `data/`), `/DATA/AppData/auth`, `/DATA/AppData/maison`, `/DATA/AppData/terminal` | `/DATA/AppData/yundera`, `/DATA/AppData/kopia` |
| Stacks | `mesh`, `auth`, `maison`, `terminal` | `yundera` (admin, admin-app), `kopia` |
| Config | its own `.env`, user-owned | `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` → unified `.env` |
| Self-check | its own list, cron entry, lock, log, migrations, markers | its own list, cron entry, lock, log, migrations, markers |
| Updates | its own channel (`UPDATE_URL` in the mesh `.env`) | its own channel (`UPDATE_URL` in `.pcs.env`) |
| Host | Docker (no-op when present), yq, cron, logrotate | pcs/admin users, sshd, swap, apt, support key, IP family, netplan |
| Control plane | none | `OPERATOR_API`, `USER_JWT`, Yundera Login, backup credentials |

Two independent crons, two independent update paths. That is a decision (below), and it works
because the two runs touch **disjoint compose projects and disjoint folders**.

## How the two runs relate

- **Install once.** At provisioning (and on a domain or provider change) this template runs
  the mesh `install.sh --yes --provider … --domain … --email … --channel …`. With `--yes` and
  no claim flags it leaves the box unclaimed, which is what a PCS wants. It must run
  **synchronously**, and its exit code must reach the orchestrator's fail-fast path — a cron
  is not enough during a create.
- **Not every night.** `install.sh` does a full `docker compose down` of the mesh stack on
  every run, deliberately, to apply an identity change cleanly. The nightly Yundera step is an
  *upsert* of the keys below into the mesh `.env`, nothing more.
- **Trigger, don't wait.** When this template changes something the mesh template reads, it
  calls the mesh script that consumes it right away — `ensure-dex.sh` after writing or
  removing the Yundera Login drop-in, the mesh `self-check.sh` after an identity change.
  Otherwise the change sits for up to a day until the mesh cron.
- **Stagger the schedules.** Both default to 03:00.
- **No `@reboot` in the mesh template**, by design. This template keeps its own.

Order on a cold box: Yundera host prep (users, Docker, user data) → mesh `install.sh` →
Yundera post steps (admin stack, backup, kopia, preinstall). Every Yundera gate needs
`auth-registrar`, so the post steps come after the mesh run, not before.

## The contract: what Yundera writes, and where

Into the mesh `.env`, with `env-file-manager.sh set` — never by regenerating the file:

| Key | From | Note |
|---|---|---|
| `PROVIDER_STR`, `DOMAIN` | orchestrator | required by `ensure-env-valid.sh` |
| `EMAIL` | `.ynd.user.env` | the mesh `ensure-email-synced.sh` also fetches it from the backend; they should agree |
| `DEFAULT_PWD` | `.pcs.secret.env` | **must be there before the first mesh run**, or `ensure-env-valid.sh` mints a second one |
| `LOCAL_ADMIN_USER` | `.pcs.env` | read by `ensure-authelia.sh` and the user manager |
| `DEFAULT_SERVICE_HOST` / `_PORT` | `.pcs.env` | or leave it to mesh-console's "default app" action |
| `TERMINAL_USER=admin` | constant | the mesh default is `root`; a PCS has an `admin` sudoer |
| `TERMINAL_ENABLED` | `.pcs.env` | opt-out |
| `UPDATE_URL` | per environment | the **mesh** channel (`.tar.gz`), not this template's `.zip` |
| `MESH_AUTO_UPDATE` | "freeze platform updates" toggle | must freeze the mesh too |
| `SELF_CHECK_CRON` | constant, staggered | |

Files: `auth/dex/connectors.d/yundera.yaml` (Yundera Login), `maison/onboarding.json` (the
onboarding gate), and — once the mesh compose has the seam for it — the Yundera-only values
listed under "Compose seams".

What Yundera **reads back** from the mesh `.env`: `PUBLIC_IP*`, once the mesh template is the
only one detecting it. The secrets the mesh template mints for itself stay there; no Yundera
stack needs them.

**The direction of the `.env` flips.** Today `deploy-stack.sh` writes the unified Yundera
`.env` *into* `/DATA/AppData/mesh/.env` on every self-check. The mesh template treats that
same file as its source of truth and mints secrets into it. One of the two has to stop; it is
this template. That flip is also what dissolves the apparent `UPDATE_URL` / `SELF_CHECK_CRON`
collision: the two templates use the same key names for different things, which only matters
while one file is a copy of the other.

## What happens to each Yundera script

| Script | Fate |
|---|---|
| `ensure-mesh-stack.sh`, `ensure-auth-stack.sh`, `ensure-authelia.sh`, `ensure-dex.sh`, `ensure-maison-stack.sh`, `ensure-terminal-stack.sh` | **deleted** — the mesh template's run |
| `ensure-public-ip.sh` | **deleted** once the reachability probe is upstream; the netplan / `ens19` part stays as a small host step |
| `tools/authelia-user-manager.sh`, `set-default-app.sh`, `provision-dex-frontend.sh` | **thin wrappers** that `exec` the mesh copy — settings-center-app, the orchestrator's `support.ts` and `demo` call them by path |
| `tools/onboarding.sh` | stays (Yundera's onboarding state), calling the mesh user manager |
| `ensure-yundera-login.sh` | stays; ends by calling the mesh `ensure-dex.sh` |
| `ensure-maison-stack.sh`'s onboarding gate | becomes a step that only writes `onboarding.json` |
| `stacks/{mesh,auth,maison,terminal}`, `caddy/`, `auth/`, `dex.config.yaml.tmpl`, `dex-theme/` | **deleted** from this tree |
| `library/stacks.sh`, `tools/deploy-stack.sh` | kept for `kopia` and `yundera` only |
| new: `ensure-mesh-installed.sh` | install once, then upsert the contract keys |
| everything host- and control-plane-related | unchanged |

## The mesh self-check on a PCS, step by step

| Mesh step | On a PCS |
|---|---|
| scripts-executable, logrotate, yq, docker | fine; no-ops after the Yundera host steps |
| `ensure-nightly-self-check` | its own cron entry, staggered |
| `ensure-env-valid` | fine once the contract keys are in |
| `ensure-template-sync` | updates the mesh folder from the mesh channel; independent of this template's sync |
| `ensure-public-ip`, `ensure-email-synced` | the mesh version wins; the Yundera one goes |
| `ensure-authelia`, `ensure-dex-session-key`, `ensure-dex` | the mesh version wins, after the ports below |
| stack pulled / up, `ensure-auth-stack` | stock compose; needs the seams below |
| `ensure-maison-stack` | stock; backup engine and onboarding gate come from Yundera inputs |
| `ensure-terminal-stack` | stock; compose files are already identical |
| `ensure-root-domain`, `ensure-route-registered` | new for a PCS, check-only. During a create a failure aborts it — confirm the retry budget covers a cold route registration |

## Done in the preparation pass (2026-10-01, unstaged in both repos)

**Layout — the two trees now agree on where state lives.**

- This template moved its state into the stack folders (`9fb7b94`): `mesh/data`,
  `auth/authelia`, `auth/dex`.
- The mesh template did the same for auth: `mesh/{auth,dex}` → `auth/{authelia,dex}`, and the
  rendered login theme `mesh/dex-frontend` → `auth/dex/frontend`. Same mechanism (a rename
  while the containers run, `restart_if_bound`), with one difference: the mesh scripts also
  perform the move themselves, because a mesh box with `MESH_AUTO_UPDATE=false` never runs
  migrations. See its `doc/alignment-with-template-root.md`, "Auth state move".
- This template's auth network is `dex-internal` again, the mesh template's name (it was
  `yundera-auth` from 2026-08-27). `ensure-auth-stack.sh` sweeps the old one once it is empty.
  This reverses a deliberate rename; the reasoning that survives is in the comment on the
  network in `stacks/auth/docker-compose.yml`.

**Scripts — "best of both" ported into the mesh template.**

- `self-check.sh` re-runs the whole list in order when the sync changed it (it used to append
  the new entries at the end), bootstraps exec bits, and tolerates a script removed mid-run —
  the behaviour of this template's runner.
- `library/authelia-ready.sh`: `ensure-authelia.sh` returns only once Authelia serves, and
  `ensure-auth-stack.sh` restarts Dex after Authelia answers whenever the deploy recreated it.

Checked locally only: `bash -n`, `docker compose config` on both auth stacks, and scratch
tests of the runner and of the state move. **Nothing has run on a box.**

## Still to do before the switch

### 1. Port the rest of the generic fixes into the mesh template — DONE (2026-10-01)

Unstaged in the mesh template, tested on watch.nsl.sh from the working tree.

| Item | Outcome |
|---|---|
| On-box OIDC back-channel | Gates: nothing to port — AppShield 3.1 takes `internal_issuer_url` from the registrar, on both templates. Dex → Authelia keeps the `host-gateway` pin and the mesh CA, which lives alone in `mesh/data/ca` (`CA_CERT_PATH`). |
| Local Account back-channel probe | a warning only on the mesh side: it renders the connector either way, since it is usually the box's only one |
| Public IP | `PUBLIC_IP_MODE=interface` is this template's detection (local interface, IPv6 fallback, drop what the backend cannot ping); the default `egress` stays the mesh template's. The probe URL comes from `PROVIDER_STR`. The netplan / `ens19` step stays here, as a host step. |
| auth-console gate as `65534` | done, including the hand-over of an existing root-owned `sessions.json` |
| `cpu_shares` | done, same weights |

Found on the way, and worth knowing here too: **the nsl.sh backend cannot ping any IPv6
address** (Cloudflare's resolver included, 2026-10-01), so `/probe` reports every IPv6 as
unreachable and this template's `ensure-public-ip.sh` clears `PUBLIC_IPV6` on every box —
holyhorse has a global IPv6 and an empty key. Harmless while every PCS has its own IPv4; an
IPv6-only box would be set to `127.0.0.1`. The mesh version sends a control address with each
probe and discards the verdict for a family whose control fails.

### 2. Compose seams for values that are really Yundera's — DONE (2026-10-01)

As `.env` keys in the mesh template, each defaulting to that template's own behaviour:

| Key | Value on a PCS | What it carries |
|---|---|---|
| `BRAND_NAME` | `Yundera` | TOTP issuer, reset-mail sender and subject tag |
| `DEX_THEME_SRC` | `/DATA/AppData/yundera/template/dex-theme` | the login theme; `dex-theme/` therefore STAYS in this tree |
| `PLATFORM_PROJECTS` | `mesh,auth,yundera,maison,kopia,terminal` | Mesh Console's Stack page |
| `OPERATOR_API`, `TRUSTED_PUBKEY_HOST_SUFFIXES` | the orchestrator URL, `yundera.com` | the support-key tag on auth-console |
| `BACKUP_ENGINE_CONTAINER` | `kopia-engine` | Maison's resident backup engine |
| `PUBLIC_IP_MODE` | `interface` | see above |
| `TERMINAL_USER` | `admin` | the Terminal's SSH user |

Mesh Console's path knobs (`MESH_HOST_ROOT`, `TEMPLATE_SCRIPTS`, `LOG_FILE`) need no seam:
the stock values point at the mesh root. Not seamed: the Authelia JWKS `key_id`
(`yundera-pcs` here, `pcs` there — one key rotation at adoption) and the `x-casaos` blocks.

### 2b. The `.env` direction — DONE (2026-10-01)

`ensure-mesh-stack.sh` no longer regenerates `/DATA/AppData/mesh/.env`. It upserts the
contract keys (`DEPLOY_ENV_KEYS`, `tools/deploy-stack.sh`) plus the constants above, and
leaves every other line alone; a file still in the old wholesale-copy shape is rebuilt once
from those keys, which drops `USER_JWT`, the backup credentials and the rest of the
Yundera-only keys from it. The secrets the mesh template would mint for itself
(`DEFAULT_PWD`, `AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, the two console secrets) are in
the list, so every box carries them in the mesh `.env` before the switch — the first half
of "Adopt the existing fleet" below.

Two keys are in the list only until the switch: `UPDATE_URL` and `SELF_CHECK_CRON`. Mesh
Console reads both from that file, and today they are this template's. The auth, maison,
kopia and terminal stacks still get a full copy of the unified `.env`; after the switch the
mesh template generates the first, second and fourth from its own.

Tested on wisera by running the changed `ensure-mesh-stack.sh` directly: no container
recreated, a second run leaves the file untouched, a key added by hand survives.

### 3. Adopt the existing fleet

The riskiest piece, and the one to rehearse on holyhorse and wisera first. A running PCS has
to be taken over in place:

- ~~Seed the mesh `.env` before the first mesh run with the secrets the box already has.~~
  Done by the upsert in §2b: once that has run on a box, `DEFAULT_PWD`, `AUTHELIA_DEX_SECRET`,
  `DEX_SESSION_KEY` and the two console secrets are already in the mesh `.env`. What is left
  at the switch is to stop sending `UPDATE_URL` / `SELF_CHECK_CRON` and write the mesh
  template's own values for them.
- State is already where the stock compose binds it (above). Left to reconcile: the
  Caddyfile (a directory mount from `yundera/template/caddy` here, a file at
  `mesh/Caddyfile` there), the theme directory name, and the two empty `template/`
  mountpoints this template creates in `mesh/` and `auth/` — the first becomes the mesh
  template's real `template/` tree.
- Compose project names already match (`mesh`, `auth`, `maison`, `terminal`), so no eviction
  is needed; the first stock `up` recreates the containers whose definition changed.
- `install.sh` takes the mesh stack down. Do the adoption with the lower-level pieces
  (lay the tree down, seed `.env`, run the mesh self-check) or accept one short outage.

### 4. Provisioning and the callers

- `pcs-init.sh` / `os-init.sh`: run the mesh install inside the provisioning sequence, with
  the mesh channel passed per environment (staging tracks `main`, prod `stable`).
- Wrappers at the old script paths (table above).
- mesh-console's update panel would show and edit the mesh channel on a PCS; decide whether
  it is hidden or locked when the box is managed.

## Decisions taken

- **Two independent crons**, one per template.
- **Each template updates its own folder from its own channel.** Consequence, accepted: a mesh
  release reaches the fleet without a Yundera release, so the Yundera layer may only depend on
  the contract above, and the mesh `stable` branch becomes a fleet-facing release.
- **Generic behaviour lives in the mesh template, in its best version**; the Yundera copy is
  deleted rather than kept in step.
- **State layout**: each stack's state in the folder named after the stack, on both templates.
- **Auth network name**: `dex-internal`, on both.

## Open

- How the mesh template is first laid down on a fresh VM: `install.sh` from jsDelivr (a second
  download at provisioning, behind a 12h cache) or a tarball this template fetches at a known
  revision.
- Whether a create should fail on the mesh run's check-only steps.
- The seam mechanism for §2: env defaults or an override file.
- `ensure-email-synced.sh` versus the orchestrator as the source of `EMAIL`.
