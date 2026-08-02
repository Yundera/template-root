# PCS onboarding — claiming the local account

Status: **design. Not implemented.**

This doc covers how a fresh PCS goes from "provisioned" to "the owner has a working
login". It replaces the CasaOS first-run wizard, which disappears with CasaOS
(see `maison-migration.md` — Maison has no authentication at all).

It assumes the local-account IdP is in place: Authelia sits behind Dex as the
"Local Account" connector, owning the PCS-local credential
(`scripts/self-check/ensure-authelia.sh`, `auth/configuration.yml.tmpl`,
`dex.config.yaml.tmpl`).

---

## The problem

Today a new user who picks "Local Account" on the Dex page has to discover two
things nobody told them: that the username is hardcoded `admin`
(`ensure-authelia.sh:193`), and that their password is `DEFAULT_PWD` — a 24-char
random generated on the host by `tools/generate-default-pwd.sh` and never shown to
them. In practice the only way through is to guess `admin` and run a password
reset. That is the whole of PCS onboarding once CasaOS's getting-started page is
gone.

There is a second, quieter problem. `DEFAULT_PWD` is also injected into every
installed app as `APP_DEFAULT_PASSWORD` / `PCS_DEFAULT_PASSWORD` / `default_pwd`
(`ensure-maison-app-mirror.sh`, `render_as_casaos()` — the injection list outlived CasaOS
itself, which was removed in migration phase 3).
It is an **app seed secret**, not a human credential. Using it as the local login
password means every app on the box ships with the PCS login password in its env.

---

## Decisions

| | Decision |
|---|---|
| Initial credential | **None.** The local account is seeded *unclaimed*: `disabled: true`, no `password` field. There is no default credential anywhere on the box. |
| `DEFAULT_PWD` | Demoted to app-seed-only. It is no longer the Authelia password. |
| Claim mechanism | A single host-side primitive, `scripts/tools/claim-local-account.sh`, with four callers. |
| Managed onboarding | **Path C** — SSO. The user proves ownership via Yundera Login, whose owner gate is already enforced server-side. No onboarding secret. |
| Onboarding secret | **Not built.** Break-glass is SSH + the claim script. |
| Entry point | One stable URL — `https://admin-${DOMAIN}/start` — that adapts to the claimed/unclaimed state. Not a single-use link. |
| Enforcement | Soft. `/start` has no skip button; Dex shows only Yundera Login until claimed. No AppShield or Maison change. |
| FOSS | `install.sh` calls the claim primitive interactively in the terminal. |
| Demo | Pre-claimed at provision time via the existing `COMMAND` channel, with `YUNDERA_OIDC=0`. |

---

## The unclaimed account model

`ensure-authelia.sh` currently seeds `admin` with an argon2 hash of `DEFAULT_PWD`.
It should instead seed:

```yaml
users:
  admin:
    disabled: true
    displayname: "Administrator"
    email: "<EMAIL from .ynd.user.env>"
    groups:
      - admins
```

No `password` key. Authelia's file backend supports `disabled` per user (see the
YAML format in Authelia's password reference guide), so "unclaimed" is a real,
enforced state rather than a convention.

This is the load-bearing simplification. It means:

- there is no default credential to leak, guess, or forget to change;
- the `DEFAULT_PWD` hygiene problem above disappears without a migration;
- "has this PCS been onboarded?" has exactly one source of truth —
  does `admin` have a `password` and `disabled: false` in
  `/DATA/AppData/yundera/auth/users_database.yml`. Everything else (the Dex
  connector list, the `/start` page, any dashboard badge) is a projection of
  that bit.

**Seeding order caveat.** `ensure-authelia.sh:171` treats "a `password:` field is
present" as the already-seeded marker and refreshes only the email on subsequent
runs. That check still works unchanged: an unclaimed file has no `password` key,
so the seed block re-runs harmlessly every tick; a claimed file has one, so the
password is never touched. The only change needed is that the seed block writes
the disabled/no-password form instead of hashing `DEFAULT_PWD`.

### Authelia config changes that go with it

In `auth/configuration.yml.tmpl`:

- `authentication_backend.file.search.email: true` and
  `search.case_insensitive: true` — the user logs in with **their own email
  address** instead of discovering `admin`. Keep `admin` as the users_database
  *key*: it is the `preferred_username` claim and therefore the OIDC `sub` that
  every app keys its per-user account on. Changing it later resets every app.
- `authentication_backend.file.watch: true` — hot-reload after the claim script
  writes the file, so no Authelia restart is needed on the claim path.
- `password_policy` (zxcvbn or standard) — the claim flow is the only place a
  password is chosen, so enforce strength there.
- `server.asset_path` pointing at a `logo.png` / `favicon.ico` / `locales/en/`
  override directory. Authelia allows **no CSS or JS injection** — those three
  are the entire branding surface. The `locales` override is how the login and
  reset copy gets reworded (e.g. "Username" → "Email address").

---

## The claim primitive

`scripts/tools/claim-local-account.sh` — one script, four callers, no UI
assumptions.

Responsibilities:

1. Take a password (argument, stdin, or interactive prompt).
2. argon2-hash it via `docker run --rm authelia/authelia:4.39 authelia crypto
   hash generate argon2` — the same image and invocation
   `ensure-authelia.sh:200` already uses for the seed and
   `ensure-authelia.sh:100` uses for the Dex client secret.
3. Write `password:` into `users_database.yml` and set `disabled: false`,
   atomically, chmod 600.
4. Re-run `scripts/self-check/ensure-dex.sh` so the Local Account connector
   appears immediately rather than at the next self-check tick.
5. Be idempotent, and support a `--force` flag that overwrites an already-claimed
   password (the demo needs this; see below).

Callers:

| Caller | Invocation |
|---|---|
| Managed (Path C) | `/start` wizard in the admin app, over its existing host SSH |
| FOSS | `install.sh`, interactively |
| Demo | orchestrator `COMMAND` channel, `--force`, fixed password |
| Break-glass | operator over SSH |

Putting the logic here rather than in the admin app's request handler is what
makes the FOSS, demo, and recovery paths fall out for free. **The invariant to
protect: the unclaimed state must always be resolvable from a terminal, with no
network dependency.** As long as that holds, everything below is a convenience
layer that cannot brick a PCS.

Hardening note: passing the password as an argv to `docker run` exposes it in
`ps` for the duration. Prefer stdin if the Authelia CLI accepts it; on a
single-owner box the exposure is small but it is free to avoid.

---

## Path C — managed onboarding

```
"Your PCS is ready" mail   (the existing provisioning mail, CTA retargeted)
        │
        ▼
https://admin-${DOMAIN}/start
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
   │  ▸ Set a local password       ← no skip      │
   │  ▸ (tour: domains, files, first app)         │
   └──────────────────────────────────────────────┘
        │  claim-local-account.sh  →  ensure-dex.sh
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

> Note: `pcs-orchestrator/CLAUDE.md` describes the owner gate as "off by
> default". That line is stale — the code and `doc/oidc-idp.md` both say always
> enforced. Worth correcting when this lands.

So "is this browser the owner of this PCS?" is answered by the Yundera Login
round-trip itself. A secret would only add a second, weaker answer to a question
already answered — plus a value to mint, mail, expire, consume, and support when
it is lost.

The scenario a secret would have covered is browser-based claim without SSH while
yundera.com is unreachable. Break-glass is SSH plus the claim script; an operator
recovering a dead PCS is at a terminal anyway.

### Why one stable, adaptive URL

`/start` is not a single-use activation page. It is the permanent entry point:
the provisioning mail links to it, the yundera.com dashboard links to it, and it
works from any device at any time because Dex re-authenticates the owner on every
visit.

The **page** decides what to render:

- unclaimed → the Getting Started wizard;
- claimed → "you're all set", pass through to Maison (honour `?rd=`).

That removes the need for any onboarded/not state to be synchronised anywhere.
The mail template never has to change again, and "I lost the email" stops being a
support case.

Optional, not required: the PCS could piggyback a `localAccountClaimed` flag on
the existing authenticated `/user/info` call to the orchestrator so the
yundera.com dashboard can render a "finish setup" badge instead of a generic
button. This buys nagging, not correctness — the flow works without it. A public
`GET /onboarding-status` on the PCS was considered and rejected: it leaks the bit
to anyone, and the authenticated channel already exists.

### Where `/start` lives

The admin app (`settings-center-app`, `admin-${DOMAIN}`). It already exists, is a
Next.js app, is an OIDC client of Dex, and SSHes to the host as the `admin`
sudoer — so it can invoke `claim-local-account.sh` with no new mounts, no new
container, no new Caddy label, and no new certificate.

### Enforcement is deliberately soft

A user who navigates directly to `maison-${DOMAIN}` gets in via Yundera Login
without ever seeing `/start`. **This is accepted.** The mitigations are:

- `/start` has **no skip button** — setting the password is the only way out of
  the wizard;
- Dex presents only Yundera Login until the account is claimed, so no second
  door is advertised;
- both the mail CTA and the dashboard button point at `/start`.

Explicitly **not** built: a redirect in the AppShield gate or in Maison that
bounces un-onboarded users. It would cover the gap, but it puts onboarding state
into an image every app on the PCS depends on, and it converts a broken wizard
into an unusable PCS. Finding another way in is enough friction.

---

## Dex connector rendering

`ensure-dex.sh` gains two conditions:

- **Local Account (Authelia)** — rendered only when the account is claimed. An
  unclaimed PCS must not advertise a login that cannot work; that is the actual
  defect in today's flow.
- **Yundera Login** — rendered only when `YUNDERA_OIDC` is not `0` *and* client
  registration succeeds. The registration-failure branch already exists
  (`ensure-dex.sh:102-162`); `YUNDERA_OIDC` adds an explicit opt-out.

`YUNDERA_OIDC` lives in `.pcs.env` and means "this PCS federates to Yundera".
`0` is the honest description of both a demo box and a FOSS box. It is checked
independently of `USER_JWT` so it works even where a JWT happens to be present.

### The never-empty invariant

Unclaimed **and** no Yundera connector = a login page with zero buttons and a PCS
nobody can enter. `ensure-dex.sh` must assert it never renders an empty connector
list, and log loudly if it is about to. The recovery for that state is the claim
script over SSH — which is exactly why the primitive must not depend on the
network.

This is the one genuinely new failure mode this design introduces, and it is the
thing most likely to be silently broken by a later change.

---

## FOSS / self-hosted

The terminal **is** the onboarding process. `install.sh` prompts for an initial
password (or generates and prints one), calls `claim-local-account.sh`, and sets
`YUNDERA_OIDC=0`. By the time the box serves its first page the account is
claimed, Dex shows Local Account only, and `/start` renders its "you're all set"
form.

No part of Path C is required for this to work, and nothing in the managed flow
may become a hard dependency of the claim primitive.

---

## Demo

Demo visitors have no Yundera account, and the owner gate is fail-closed — a
stranger's Firebase uid is denied (`validation.ts:50`). So Yundera Login is not
merely useless on a demo box, it is an actively bad experience: sign in, get
`AccessDenied`. **A demo PCS must ship pre-claimed with a published local
credential.**

The `demo` package already has the right hook: `buildDemoCommand()` in
`src/lib/DemoManager.ts` concatenates optional bash fragments into the single
`COMMAND` the orchestrator runs on the freshly-provisioned host. Add a
`buildLocalAccountClaimCommand()` alongside `buildAppDataPreloadCommand()` and
`buildAnalyticsInjectionCommand()` that:

1. calls `claim-local-account.sh --force` with the published demo password —
   `--force` is required because demos re-provision daily and the seed logic
   deliberately never overwrites an existing password;
2. sets `YUNDERA_OIDC=0` via `tools/env-file-manager.sh` and re-runs
   `ensure-dex.sh`.

Result: no wizard, no nag, one connector, and the demo page's existing
copy-to-clipboard credential UI keeps working unchanged.

### Rejected: no-auth demo

Running the demo with authentication disabled ("Dex passes all") was considered
and rejected. Maison mounts the Docker socket and the AppShield gate is the only
thing in front of it, so an open demo box is unauthenticated root on the public
internet — abusable for mining, spam relay, or hosting content under the Yundera
domain in the hours between resets. Disposability bounds data loss, not liability.
Published credentials cost the visitor one paste, and the login is now part of
what the demo is showing.

### Demo-specific items

1. **Regulation is per-username, not per-IP.** Authelia bans the account after 5
   failures in 2 minutes for 10 minutes
   (`configuration.yml.tmpl:62-65`). On a shared demo box, one visitor fumbling
   the password locks `admin` out **for every visitor** for ten minutes. Loosen
   or disable `regulation` on demo instances.
2. **The analytics hook dies with CasaOS.** `buildAnalyticsInjectionCommand()`
   `docker cp`s a `custom.js` into `casaos:/var/lib/casaos/www/js/custom.js` to
   detect login and `postMessage` to the demo iframe. Authelia allows no JS
   injection (logo, favicon, locales only), so this needs a new source of the
   login-success signal.
3. **Cookie `same_site` in the iframe.** The demo embeds the PCS in an iframe and
   the OIDC chain already crosses `maison-…` → `auth-…` → `casaos-oidc-…`
   there today, so cross-origin redirects in a nested context are evidently fine
   in this setup. The one new variable is that
   `configuration.yml.tmpl:44` sets Authelia's session cookie to
   `same_site: 'lax'`, and a Lax cookie is not sent on cross-site redirects
   inside a nested browsing context. Check what Dex and the bridge set and match
   it (likely `none`, whose `Secure` requirement is already satisfied — every
   origin is HTTPS). One line of config; verify on the demo as soon as Authelia
   is in the chain.

---

## Change list

| Package | Change |
|---|---|
| `template-root` | `ensure-authelia.sh`: seed unclaimed (`disabled: true`, no password), stop consuming `DEFAULT_PWD` |
| | `auth/configuration.yml.tmpl`: `search.email`, `search.case_insensitive`, `watch`, `password_policy`, `asset_path`, `same_site` review |
| | new `scripts/tools/claim-local-account.sh` |
| | `ensure-dex.sh`: conditional Authelia connector, `YUNDERA_OIDC` gate, never-empty assertion |
| | `.pcs.env.example`: document `YUNDERA_OIDC` |
| | new `auth/assets/` (logo, favicon, `locales/en`) |
| `settings-center-app` | `/start` Getting Started page + API route that invokes the claim script over host SSH; adaptive on claimed state; no skip button |
| `pcs-orchestrator` | retarget the provisioning mail CTA to `admin-${DOMAIN}/start`; correct the stale owner-gate line in `CLAUDE.md`; *(optional)* accept `localAccountClaimed` on `/user/info` |
| `demo` | `buildLocalAccountClaimCommand()`; `YUNDERA_OIDC=0`; loosen regulation; replace the CasaOS analytics injection |
| yundera.com dashboard | *(optional)* "Finish setup" button → `admin-${DOMAIN}/start` |

Nothing changes in AppShield or Maison.

---

## Open items

- **Getting Started scope.** Beyond the password, how much of the CasaOS
  getting-started page gets rebuilt (domain explainer, where files live, install
  your first app, mail setup)? Additive — it does not change anything above.
- **Passkeys.** Once a local password exists, Authelia 4.39 can enrol a passkey
  from its settings portal. A good follow-up so the independent credential is
  pleasant to use day-to-day rather than the one nobody touches.
- **`DEFAULT_PWD` rename.** Its only remaining job is seeding app credentials.
  The name now overstates what it is.
- **Reset-flow copy.** `identity_validation.reset_password.jwt_lifespan`
  defaults to 5 minutes. Fine for a genuine reset; check it is not being relied
  on for anything onboarding-shaped.
