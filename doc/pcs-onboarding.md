# PCS onboarding — claiming the local account

Status: **implemented.**

| Piece | State |
|---|---|
| Unclaimed seed (`ensure-authelia.sh`) | ✅ implemented |
| `claim` verb (`tools/authelia-user-manager.sh`) | ✅ implemented |
| Conditional Local Account connector (`ensure-dex.sh`) | ✅ implemented |
| `tools/onboarding.sh` + deployment override | ✅ implemented |
| First-start wizard (`settings-center-app`) | ✅ implemented |
| Provisioning-mail CTA (`pcs-orchestrator`) | ✅ implemented |

This doc covers how a fresh PCS goes from "provisioned" to "the owner has a
working login". It replaces the CasaOS first-run wizard, which disappeared with
CasaOS (see `maison-migration.md` — Maison has no authentication of its own).

The local-account IdP it assumes is in place: Authelia sits behind Dex as the
"Local Account" connector, owning the PCS-local credential
(`scripts/self-check/ensure-authelia.sh`, `auth/configuration.yml.tmpl`,
`dex.config.yaml.tmpl`).

---

## The problem

A new PCS used to seed Authelia's `admin` with `DEFAULT_PWD` — a 24-char random
generated on the host and **never shown to the owner**. The only way in was to
guess the username `admin` and run a password reset. Meanwhile the Dex login page
advertised a "Local Account" button that, in practice, nobody could use.

There was a second, quieter problem. `DEFAULT_PWD` is also injected into every
installed app as `APP_DEFAULT_PASSWORD` / `PCS_DEFAULT_PASSWORD` / `default_pwd`
(`ensure-maison-app-mirror.sh`, `render_as_casaos()` — the injection list outlived
CasaOS itself). It is an **app seed secret**, not a human credential. Using it as
the local login password meant every app on the box shipped with the PCS login
password in its environment.

---

## Decisions

| | Decision |
|---|---|
| Initial credential | **None.** The owner account is seeded *unclaimed*: `disabled: true`, with a throwaway hash nobody ever learns. There is no usable default credential on the box. |
| `DEFAULT_PWD` | Demoted to app-seed-only. No longer the Authelia password. |
| Username | **Chosen by the owner at onboarding.** `admin` is only the seed placeholder; the claim renames it. |
| Password | **Chosen by the owner**, passed on stdin. `--generate` mints one instead (demo, scripted provisioning). |
| Claim mechanism | A subcommand of the existing host script — `authelia-user-manager.sh claim` — not a separate primitive. |
| Managed onboarding | **Path C** — SSO. The owner proves ownership via Yundera Login, whose owner gate is enforced server-side. No onboarding secret. |
| Break-glass | **The Yundera support SSH key**, which already exists and is independent of the whole login chain. |
| Entry point | One stable URL — `https://admin-${DOMAIN}` — that adapts to the claimed/unclaimed state. Not a single-use link, and not a dedicated route: the wizard gates the whole admin app shell. |
| Enforcement | Soft. The wizard has no skip button; Dex shows only Yundera Login until claimed. No AppShield or Maison change. |

---

## The unclaimed account model

`ensure-authelia.sh` seeds:

```yaml
users:
  admin:                      # placeholder — the claim renames this
    disabled: true
    displayname: "Administrator"
    password: "<throwaway argon2 hash, random, never printed>"
    email: "<EMAIL from .ynd.user.env>"
    groups:
      - admins
```

`disabled: true` is enforced by Authelia at authentication, not merely
cosmetically: a login attempt with the *correct* password is refused as **`user
not found`** (verified against `authelia/authelia:4.39`). "Unclaimed" is
therefore a real, enforced state.

### Two constraints that are NOT negotiable

Both were verified against the image, and violating either is **fatal at
startup** — Authelia exits and takes every interactive login on the PCS with it:

1. **A user entry must carry a non-empty `password:`.** Seeding the unclaimed
   state as a bare `disabled: true` with no password field — which an earlier
   draft of this document specified — dies with:
   ```
   could not validate the schema: Users.admin.users: non zero value required
   ```
   Hence the throwaway hash. It is random, never stored anywhere else, and
   unusable precisely because the account is disabled.
2. **`users:` must not be empty.** So the placeholder cannot simply be omitted
   and created for the first time by the claim:
   ```
   could not validate the schema: users: non zero value required
   ```
   Hence a placeholder entry that the claim **renames**.

### What "claimed" means

**At least one user in `users_database.yml` that is not `disabled`.**

Deliberately a property of the file rather than of a particular username: it
survives the rename the claim performs, and stays correct once the box has
several accounts. `ensure-dex.sh` and `authelia-user-manager.sh` (`is_claimed`)
evaluate the same predicate — keep them in sync.

Note this is *not* the same as the seed marker in `ensure-authelia.sh`, which
greps for a `password:` field. Because the unclaimed seed also writes one, that
check remains a pure "has this file been written yet?" test and is unaffected by
onboarding. **Do not conflate the two.**

### Where the chosen username is recorded

`LOCAL_ADMIN_USER`, in **`.pcs.env`**.

Not `.ynd.user.env`: that file is re-fetched from the orchestrator's
`/user/info` on every self-check tick by `ensure-yundera-user-data.sh`, which
would clobber a locally-chosen value. The username is host-local state.

Absent means `admin` — which is exactly right for every PCS provisioned before
onboarding existed. Two readers:

- `ensure-authelia.sh`, so the owner's email keeps being stamped onto the right
  block after a rename;
- `authelia-user-manager.sh`, as `PROTECTED_USER` (the account that cannot be
  deleted or have its email changed locally).

### Why the username is chosen once, at claim time

The username is the OIDC `preferred_username`, which every app on the PCS keys
its per-user account on. Choosing it **at onboarding is free** — nothing has
logged in yet. Changing it later is not: it would orphan every app-side account.
That is why there is no `rename` subcommand and why `claim` refuses to run a
second time without `--force`.

---

## The claim verb

```bash
# owner-chosen password, never in argv (stdin → env var → container)
printf '%s' 'their-password' | authelia-user-manager.sh claim pierre "Pierre H"

# generated instead, returned once in the JSON
authelia-user-manager.sh claim --generate owner "The Owner"
```

In one atomic write it renames the placeholder to the chosen username (carrying
the email and groups forward), sets the password, and clears `disabled` — then
records `LOCAL_ADMIN_USER` and re-runs `ensure-dex.sh` so the Local Account
connector appears immediately rather than at the next tick.

Password handling differs from the other subcommands on purpose. `add` and
`set-password` use `authelia crypto hash generate argon2 --random` because the
Authelia CLI refuses piped stdin and `--password` would put the secret in the
**host's** process list. The claim needs a *specific* password, so it passes the
plaintext as an environment variable and expands it inside the container
(`docker run -e SECRET … sh -c 'authelia … --password "$SECRET"'`). The plaintext
is never in the host command line, never in the script's argv, and never on
disk; it is briefly visible in the container's process table, i.e. to root on
this host — who already owns the hash file and can reset any credential anyway.

Callers: `onboarding.sh` (which the admin app's wizard drives over its existing
host SSH), an operator over SSH, and scripted provisioning via `--generate`.

**The invariant to protect: the unclaimed state must always be resolvable from a
terminal, with no network dependency.** As long as that holds, everything below
is a convenience layer that cannot brick a PCS.

---

## The onboarding hook — `scripts/tools/onboarding.sh`

The admin app does not know what onboarding *is*. It collects a credential and
calls one host script; that script decides what happens. This is the same
reasoning as `dex/connectors.d`: a deployment changes behaviour by replacing a
file, and the shipped product carries no branch for it.

```
onboarding.sh status            -> {"claimed":bool,"completed":bool,"username":str}
onboarding.sh run               -> performs onboarding (password on stdin)
onboarding.sh mark-completed    -> records that the wizard was seen
```

**Override**: if `/DATA/AppData/yundera/onboarding.d/onboarding.sh` exists and is
executable, it is `exec`'d in place of the shipped one. It lives in the runtime
data dir on purpose — editing the template copy in place on a live PCS looks like
it works and is then silently reverted by the next `ensure-template-sync.sh`
rsync, since `root/.ignore` preserves only the env files, logs, `*.backup` and
`migration-markers/`.

**Inputs**: `ONBOARDING_USERNAME` (required), `ONBOARDING_DISPLAYNAME`,
`ONBOARDING_GENERATE=1`; the **password arrives on stdin**. That split is not
stylistic. The admin app reaches the host by base64-ing its whole command into an
ssh argv (`HostExecutor.ts`), so a password in the environment would sit
decodable in `ps` on both the container and the host. `executeHostCommand` grew
an optional `stdin` for exactly this. Anything replacing this script must keep
the split.

**Two states, deliberately not conflated** — the same distinction the rest of this
document turns on:

| | Source | Cost of being wrong |
|---|---|---|
| `claimed` | derived from `users_database.yml` on every call | box is unreachable |
| `completed` | marker at `/DATA/AppData/yundera/onboarding/completed` | a redundant welcome screen |

Deriving `claimed` is what keeps a restored backup or a migrated PCS honest: the
migration pipeline copies `/DATA/AppData/yundera/auth/`, so a marker-driven
wizard would either nag forever on a claimed box or — far worse — refuse to
appear on an unclaimed one, stranding an owner with no credential and no Local
Account connector to make one with. The marker only ever suppresses the welcome.

Marker placement follows from the same constraint: `/DATA/AppData/yundera/` is
user data (backed up, carried by migration), not the template tree.

`run` writes the marker **only after** the claim succeeds, so a half-finished
onboarding is re-runnable, and it refuses outright on an already-claimed box
(re-claiming would rename the owner account).

### The wizard

`OnboardingGate` wraps the app shell rather than sitting on a route — "first
start" has to be unavoidable, and a route can be navigated away from. Unclaimed
renders a blocking dialog with no skip and no close; claimed-but-never-welcomed
renders a dismissible one over a live dashboard. If the status call fails it
renders the app untouched: a broken endpoint must never lock a working dashboard
behind a modal.

It is a **convenience over the script, never the only path**. The admin app
redirects unauthenticated loads to Dex, and an unclaimed FOSS box may legitimately
have no connectors at all — so on that box nobody can reach the wizard and the
terminal is the way in, by design.

---

## Dex connector rendering

**Local Account (Authelia) is rendered only when the account is claimed.** An
unclaimed PCS must not advertise a login that cannot work — that was the actual
defect in the old flow. The connector moved out of `dex.config.yaml.tmpl` into a
conditional append in `ensure-dex.sh`, the same append-on-condition shape the
Yundera Login connector already used.

The check **fails open**: on any doubt (`yq` missing, unreadable file, malformed
YAML) the connector is rendered. Guessing "unclaimed" on a box that is actually
claimed would hide the owner's only door; guessing "claimed" on a fresh box
merely restores the old cosmetic wart. The asymmetry is deliberate.

**Yundera Login** is rendered when `OPERATOR_API` + `USER_JWT` are present and
client registration succeeds; on any failure it is skipped and login continues
via Authelia. Login must never hard-depend on the Yundera cloud.

### The never-empty case

Unclaimed **and** no Yundera connector = a login page with zero buttons.
`ensure-dex.sh` logs this loudly, with the fix command, but does **not** treat it
as an error — Dex starts fine with an empty connector list, and this is a
legitimate transient state on a fresh box, not a config fault.

It is not a brick, because the recovery path is SSH and therefore independent of
this entire chain:

```bash
ssh admin@<host>
sudo /DATA/AppData/casaos/apps/yundera/scripts/tools/authelia-user-manager.sh claim <username>
```

The **Yundera support key** guarantees that access on managed boxes:
`ensure-support-key.sh` re-asserts it into `admin@host`'s `authorized_keys` every
self-check tick, it is on by default (`ENSURE_SUPPORT_KEY`), and during first
boot it is mandatory — a missing support key aborts provisioning rather than
shipping an unreachable PCS. The dashboard toggle can only opt *out*, so there is
no circular "log in to regain access" dependency.

Two residual cases, both accepted: an owner who sets `ENSURE_SUPPORT_KEY=false`
*and* loses Yundera Login is genuinely stuck (self-inflicted), and FOSS boxes get
no support key — but their owner has root on their own machine.

---

## Path C — managed onboarding

```
"Your PCS is ready" mail   (the existing provisioning mail, CTA retargeted)
        │
        ▼
https://admin-${DOMAIN}
        │  not authenticated
        ▼
      Dex  →  [ Log in with Yundera ]      ← the only connector while unclaimed
        │
        ▼  Firebase — the password they set on yundera.com minutes ago
        │
        ▼  owner gate: uid == owner_uid    ← already enforced, see below
        │
   Getting Started (admin app)
   ┌──────────────────────────────────────────────┐
   │  Your PCS is live at …                       │
   │  ▸ Choose your username + password ← no skip │
   │  ▸ (tour: domains, files, first app)         │
   └──────────────────────────────────────────────┘
        │  authelia-user-manager.sh claim  →  ensure-dex.sh
        ▼
   Maison  (or ?rd= target)
```

### Why no onboarding secret

The obvious design is a one-time secret minted at provisioning and mailed as
`?s=…`. It is unnecessary, because **the ownership proof already exists
server-side**.

`pcs-orchestrator` registers each PCS's OIDC client with `owner_uid` bound,
authenticated by that PCS's `USER_JWT` (`src/service/oidc/pcsClient.ts:32-76`),
and the authorization policy denies any authenticated uid that is not the
registered owner — fail-closed, no opt-out flag
(`src/service/oidc/validation.ts:39-51`, wired unconditionally at
`src/service/oidcAPI.ts:120`; documented at `doc/oidc-idp.md:143`).

> `pcs-orchestrator/CLAUDE.md` used to describe this gate as "off by default",
> which was never true of the code. Corrected when this landed.

So "is this browser the owner of this PCS?" is answered by the Yundera Login
round-trip itself. A secret would only add a second, weaker answer to a question
already answered — plus a value to mint, mail, expire, consume, and support when
it is lost.

### Why one stable, adaptive URL

The admin app URL is not a single-use activation page. It is the permanent entry point:
the provisioning mail links to it, the yundera.com dashboard links to it, and it
works from any device at any time because Dex re-authenticates the owner on every
visit.

The **page** decides what to render:

- unclaimed → the Getting Started wizard;
- claimed → "you're all set", pass through to Maison (honour `?rd=`).

That removes the need for any onboarded/not state to be synchronised anywhere.
The mail template never has to change again, and "I lost the email" stops being a
support case. `authelia-user-manager.sh list` now returns a `disabled` field per
user, which is how the page tells the two states apart.

### Where the wizard lives

The admin app (`settings-center-app`, `admin-${DOMAIN}`). It already exists, is a
Next.js app, is an OIDC client of Dex, and SSHes to the host as the `admin`
sudoer — so it can invoke the claim with no new mounts, no new container, no new
Caddy label, and no new certificate.

### Enforcement is deliberately soft

A user who navigates directly to `maison-${DOMAIN}` gets in via Yundera Login
without ever seeing the wizard. **This is accepted.** The mitigations are:

- the wizard has **no skip button** — claiming the account is the only way out of
  the wizard;
- Dex presents only Yundera Login until the account is claimed, so no second
  door is advertised;
- both the mail CTA and the dashboard button point at the admin app.

Explicitly **not** built: a redirect in the AppShield gate or in Maison that
bounces un-onboarded users. It would cover the gap, but it puts onboarding state
into an image every app on the PCS depends on, and it converts a broken wizard
into an unusable PCS.

---

## FOSS / self-hosted

The terminal **is** the onboarding process. The installer prompts for a username
and password (or uses `--generate` and prints the result), calls `claim`, and the
box serves its first page already claimed: Dex shows Local Account, the admin app
renders "you're all set".

No part of Path C is required for this to work, and nothing in the managed flow
may become a hard dependency of the claim.

---

## Demo — solved differently, no claim involved

The earlier plan here — pre-claim each demo box with a published password — was
**superseded and should not be revived**. `demo/src/lib/DemoManager.ts`
(`buildOpenEntryAuthCommand()`) instead deploys `navikt/mock-oauth2-server` to
`/DATA/AppData/.demo-auth` and drops an "Open Entry" connector into Dex's
`connectors.d/`. A visitor is in without typing anything.

That is strictly better here: no published credential to rotate, no shared
account to lock out, and — because the presence of the drop-in file *is* the
condition — no auth-bypass path that could ever ship to a real user's PCS.

Open Entry is also the demo's **only** connector, which is why the visitor sees
no login screen at all: Local Account is absent (the box is never claimed) and
Yundera Login is switched off with `YUNDERA_LOGIN_ENABLED=0` in the demo's
`PCS_ENV`. That connector federates to the orchestrator IdP, whose owner policy
admits only the PCS's owner — the demo service's own account — so on a demo box
it could only ever take a visitor's real credentials and then deny them. With a
single connector left, Dex skips its chooser and redirects straight through.

Two consequences for this document: the demo needs no `YUNDERA_OIDC` flag (the
concept was dropped entirely), and Authelia's per-username regulation lockout is
no longer a shared-demo-box concern because no visitor ever types a password.

One item survives: `buildAnalyticsInjectionCommand()` used to `docker cp` a
`custom.js` into CasaOS to detect login and `postMessage` to the demo iframe.
CasaOS is gone and Authelia allows no JS injection, so that signal needs a new
source.

---

## Change list

| Package | Change | State |
|---|---|---|
| `template-root` | `ensure-authelia.sh`: seed unclaimed, stop consuming `DEFAULT_PWD`, resolve `LOCAL_ADMIN_USER` | ✅ |
| | `authelia-user-manager.sh`: `claim` verb, `disabled` in `list`, `PROTECTED_USER` from `LOCAL_ADMIN_USER` | ✅ |
| | `ensure-dex.sh`: conditional Authelia connector, never-empty warning | ✅ |
| | `dex.config.yaml.tmpl`: connector block lifted out into the script | ✅ |
| `settings-center-app` | `OnboardingGate` around the app shell + API routes invoking `onboarding.sh` over host SSH; adaptive on claimed state; no skip button | ✅ |
| | `AutheliaUsers.ts`: `PROTECTED_USER` is still the literal `'admin'`. It is only a 400-vs-500 nicety (the script is the enforcing copy), but it is wrong after a rename | ❌ |
| `pcs-orchestrator` | provisioning mail CTA retargeted to `admin-${DOMAIN}`; stale owner-gate line in `CLAUDE.md` corrected; shared `adminUrl()` helper | ✅ |
| yundera.com dashboard | *(optional)* "Finish setup" button → `admin-${DOMAIN}` | ❌ |

Nothing changes in AppShield or Maison.

---

## Open items

- **Getting Started scope.** Beyond the credential, how much of the CasaOS
  getting-started page gets rebuilt (domain explainer, where files live, install
  your first app, mail setup)? Additive — it does not change anything above.
- **Password policy.** `auth/configuration.yml.tmpl` has no `password_policy`, so
  a password chosen at claim time or via Authelia's portal is unconstrained. The
  claim enforces a bare 8-character minimum of its own.
- **Login by email.** `authentication_backend.file.search.email` is still off, so
  the local login is by username. Less critical now that the owner chooses that
  username, but still a discoverability win.
- **Branding.** Authelia allows no CSS/JS injection — `server.asset_path` (logo,
  favicon, `locales/en`) is the entire surface, and is currently unset. Lower
  priority than it looks: Dex owns the page users normally see and is themed
  (`dex-theme/`); Authelia's own page appears only on the local-account leg.
- **Passkeys.** Once a local password exists, Authelia 4.39 can enrol a passkey
  from its settings portal — a good follow-up so the independent credential is
  pleasant day-to-day.
- **`DEFAULT_PWD` rename.** Its only remaining job is seeding app credentials.
  The name now overstates what it is.
