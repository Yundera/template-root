# PCS onboarding options — mapping toggles to features

Status: **host side implemented; dashboard side not started.** The three features in
"Shipping now" now exist as `scripts/tools/feature-*.sh` and are callable over SSH today.
What is missing is the TypeScript that calls them and the wizard that renders them.
Everything under "Not toggles yet" is blocked on work that is described here but not
scheduled.

Companion to [`pcs-onboarding.md`](./pcs-onboarding.md), which covers claiming the local
account — the one onboarding step that already exists. This document covers everything the
wizard offers *in addition* to that: the opt-outs for the parts of a PCS that are not
self-hosted.

---

## Why this document

The onboarding wizard wants to offer a row of toggles:

> nsl.sh domain · sslip.io access · mail · Yundera support key · Yundera Login ·
> automated platform updates · automated app updates · *"opt out of everything"*

Seven plausible-looking switches. **Three of them can be implemented today, two belong to
architecture work that has not started, one does not exist as a feature at all, and one is
not a host-level switch in the first place.** Shipping all seven as toggles would mean four
controls that do nothing, which is a worse first impression than a shorter, honest list.

This document records which is which, why, and what each one costs — so the wizard is built
against what the box can actually do.

---

## The rule that decides everything below

> **A container can be opted out of by not installing it. A self-check script cannot — the
> host layer is never uninstalled.**

`/DATA/AppData/casaos/apps/yundera/scripts/` runs from cron on every box forever, before
Maison exists and regardless of which stacks are deployed
([`stack-split.md`](./stack-split.md) keeps it that way deliberately). So anything enforced
by an `ensure-*.sh` needs a real flag, and the stack split will not retire it.

That is why the list divides the way it does. Most of the interesting opt-outs are enforced
by self-check scripts, not by the presence of a container.

---

## The map

| Onboarding option | Mechanism | Where it lives | Status |
|---|---|---|---|
| Yundera support key | `ENSURE_SUPPORT_KEY` | `.pcs.env` | **script done** — `feature-support-key.sh`; needs UI |
| Yundera Login | `YUNDERA_LOGIN_ENABLED` | `.pcs.env` | **script done** — `feature-yundera-login.sh`; needs UI |
| Automated platform updates | `UPDATE_URL` | `.pcs.env` | **script done** — `feature-platform-updates.sh`; needs UI |
| sslip.io / nip.io access | Maison `usersettings.Domains` | Maison state | not a host flag — see below |
| nsl.sh domain | stack presence (`nsl-provider/`) | — | blocked on the stack split |
| Mail (password reset) | stack presence, *currently bundled with nsl.sh* | — | blocked on the split **and** on a BYO-SMTP mode |
| Automated app updates | Maison scheduler | Maison state | the feature does not exist yet |
| "Opt out of everything" | writes the individual flags | — | ships with whatever the others do |

---

## Shipping now: three features

### The shape

**One script per feature, self-contained, and deliberately dumb.** A feature script owns
where its flag lives, how "off" is spelled, and what enabling and disabling actually do. It
sources nothing, so it can be read, copied or replaced on its own — the property that
matters for a deployment that wants to swap one.

They live in `root/scripts/tools/` beside `onboarding.sh` and `authelia-user-manager.sh`:

```
feature-<name>.sh status     -> {"id":"<name>","enabled":true|false}
feature-<name>.sh enable     -> does it, prints the same
feature-<name>.sh disable    -> does it, prints the same
```

STDOUT is a machine interface: one JSON object, diagnostics on stderr, non-zero exit on
failure. Same shape as `onboarding.sh` and `authelia-user-manager.sh`, so the dashboard
parses them with the existing `run()` helper.

**These are root admin scripts, and they do not police the caller.** No lock states, no
refusals, no interlocks. Anyone who can run them already has root and can edit `.pcs.env` by
hand anyway, so a guard in the script buys nothing and costs the duplication it takes to
evaluate one. Policy belongs one level up — see *Guards belong in the wizard* below.

### What a script does that writing the env cannot

**Apply now, not at 03:00.** A toggle whose effect appears at the next nightly tick reads as
broken, so each script re-runs the `ensure-*.sh` that owns its state. Except updates, where
"apply" would mean performing an update — see feature 3.

The support key needs a second thing: `ensure-support-key.sh` has no removal path by design,
so disabling has to remove the key itself or "off" is a lie.

### Why the self-check side needs no changes

`self-check.sh` never aborts early — every `ensure-*.sh` runs regardless of earlier
failures — so an early `exit 0` in a gated script is safe. Both existing flags already work
this way, and `.pcs.env` is in `root/.ignore`, so a flag survives
`ensure-template-sync.sh`'s `rsync -a --delete`.

### Guards belong in the wizard, not the scripts

Two situations are genuinely dangerous, and both are UI requirements rather than script
behaviour. The scripts will happily do either; nothing stops a root shell, and nothing
should.

| Do not offer | When | Why |
|---|---|---|
| Disabling **Yundera Login** | the PCS is unclaimed | Dex renders no Local Account connector until a local account exists, so this is the only interactive login — and it is how whoever is reading the wizard got in. Off leaves the support SSH key: a terminal, for someone using a browser. |
| Disabling the **support key** | unclaimed *and* Yundera Login already off | that combination leaves no way into the box at all |

The wizard already has the predicate it needs: `onboarding.sh status` reports `claimed`.
Read it there and grey the toggle out with an explanation, rather than re-deriving
claimed-ness in three more places.

Same reasoning that keeps `onboarding.sh reset` terminal-only — that script spells it out:
unclaiming is a self-lockout button, acceptable at a root shell and unacceptable as a
control in a dashboard.

---

### 1. Yundera support key — `feature-support-key.sh`

| | |
|---|---|
| Flag | `ENSURE_SUPPORT_KEY` in `.pcs.env` |
| Polarity | absent / `true` / `1` / `yes` / `on` = ensure (default); `false` / `0` / `no` / `off` = opt out |
| Enforced by | `scripts/self-check/ensure-support-key.sh:48` |
| Already wired | `SupportEnsure.ts`, `api/admin/support-ensure.ts`, `SupportPanel.tsx` |

The most complete of the three — this is the reference implementation the other two should
copy.

**`disable` must do two things.** The self-check script only ever *adds*; it never removes.
Immediate removal from `admin@host`'s `authorized_keys` is a separate operation, today done
by `SupportAccess.ts` at toggle time. The feature script must do both, or "off" leaves the
key in place until someone deletes it by hand.

**Gap to close:** opting out should also disable the in-PCS support options. `SupportPanel.tsx`
does not read the flag today, so the panel keeps offering support actions that the operator
can no longer act on.

> **Never disable during provisioning.** On first boot the support key is the *only*
> credential that lets the orchestrator back into the box after handover, which is why
> `ensure-support-key.sh` aborts provisioning outright if it cannot install one. The toggle
> is for a box that is already up. Nothing in the script enforces this; it does not need to,
> because provisioning finishes before anyone reaches a wizard.

---

### 2. Yundera Login — `feature-yundera-login.sh`

| | |
|---|---|
| Flag | `YUNDERA_LOGIN_ENABLED` in `.pcs.env` |
| Polarity | absent = enabled (default); `0` / `false` / `no` / `off` = disabled |
| Enforced by | `scripts/self-check/ensure-yundera-login.sh:86` |
| Already wired | nothing — script only, no UI |

The script is already correct and fail-open: it writes a single drop-in,
`dex/connectors.d/yundera.yaml`, and removes it on any doubt. `disable` needs only to write
the flag and re-run the script, which re-renders Dex itself via `rerender_dex()`.

> **This is the dangerous one.** Disabling Yundera Login on an unclaimed PCS is a
> self-lockout: Dex offers no Local Account connector until a local account exists, so this
> is the only interactive login, and it is how whoever is reading the wizard got in. The
> remaining way back is the support SSH key — a terminal, for someone who was using a
> browser. Worse in combination: **support key off + Yundera Login off + unclaimed = an
> unreachable box.**
>
> The script does not stop you, by design. See *Guards belong in the wizard* above — the
> wizard reads `claimed` from `onboarding.sh status` and greys the toggle out there.

---

### 3. Automated platform updates — `feature-platform-updates.sh`

| | |
|---|---|
| Flag | `UPDATE_URL` in `.pcs.env` — a channel, not a boolean |
| Values | a `.zip` URL (default `…/template-root/archive/refs/heads/stable.zip`), or the literal `local` |
| Enforced by | `scripts/self-check/ensure-template-sync.sh:81` |

**No new flag is needed here, and this is worth stating explicitly because it is not
obvious.** `UPDATE_URL=local` makes the sync skip the download entirely and run only the
on-disk migrations. And because **every platform image is pinned to an exact version inside
the template tree** — ten directly in the compose files (Dex by digest), plus `KOPIA_IMAGE`
in `scripts/library/kopia.sh` — the template *is* the version manifest. Freezing it
therefore freezes the images too: `ensure-user-compose-pulled.sh` keeps running but re-pulls
the same tags.

So one existing variable covers both halves of "no automated platform updates". Separate
`TEMPLATE_UPDATE_ENABLED` / `STACK_IMAGE_UPDATE_ENABLED` flags would be redundant.

Three things the script must handle:

1. **Preserve the previous value.** `disable` stashes the current channel in
   `UPDATE_URL_PREVIOUS` and `enable` puts it back. Otherwise re-enabling would have to guess
   the default, silently discarding a custom fork or branch URL. Both directions are
   idempotent: a second `disable` will not overwrite the stash with the sentinel, and
   `enable` only ever undoes *our* freeze — on a box that is not frozen it is a no-op, so it
   cannot clobber a custom `UPDATE_URL` or drag a dev box back to the default.
2. **Do not conflate frozen with dev mode.** `local` means "a developer is testing on this
   box". *Resolved by adding a second sentinel:* `ensure-template-sync.sh` now accepts
   `frozen` with identical behaviour and the feature script writes only that, so the file
   still says which of the two happened. Freezing a `local` box stashes `local` and
   unfreezing restores it, so the round-trip is lossless.
3. **Say what "off" actually means.** Migrations still run in local mode — harmless, since
   markers make them one-shot, but the UI copy should be *"no new code arrives"*, not
   *"nothing changes"*. And the real cost belongs on screen: **security fixes stop
   arriving**, and a box frozen for months replays a long migration chain when it is
   unfrozen.

> **Not the same thing as `SELF_CHECK_CRON`.** That flag (`disabled` / `off`) stops the
> nightly cron entirely — updates *and* every self-healing behaviour, including the support
> key safety net and backup credential rotation. It is a debugging tool, not an update
> preference. Do not wire a wizard toggle to it.

---

## Not toggles yet

### sslip.io / nip.io — not a host flag at all

**There is no ensure script for this.** The only self-check scripts that touch Caddy are
`ensure-public-ip.sh` (which sets `PUBLIC_IP_DASH`) and `ensure-template-sync.sh` (which
copies the Caddyfile). sslip.io access comes from two places, neither of them a script:

- hardcoded `caddy_1:` / `caddy_2:` labels in the platform compose files and in roughly 220
  store apps that have not been migrated;
- Maison's `internal/domains` for routes it generates itself.

> ### Do not implement this by blanking `PUBLIC_IP_DASH`
>
> The Caddyfile documents what happens: empty interpolation produces malformed hostnames,
> Caddy retries ACME against them every five minutes per host, and CPU pegs. That failure is
> the reason `cert_issuer internal { lifetime 168h }` exists — it caps a ~28,800/day retry
> storm at ~22 renewals/day. Blanking the variable re-creates the problem the fallback was
> added to contain.

The good news is that Maison already models the right thing: `internal/domains` treats the
deployment's domain list as user settings — the entries are literally named `sslip`, `nip`,
`lan` — and `internal/routes` generates the labels from it. sslip.io is a **checkbox in that
list**, not a stack and not a flag.

**Blocked on:** finishing the routes migration so Maison owns the labels, or a filter in
`mesh-router-caddy`'s entrypoint. Until then there is nothing for a toggle to switch.

**In the wizard:** describe it, do not offer it.

---

### nsl.sh domain — blocked on the stack split

[`stack-split.md`](./stack-split.md) puts `mesh-router-agent`, `mesh-router-tunnel` and
`smtp` in an `nsl-provider/` folder, and the evidence that this is the right boundary is
strong: **`PROVIDER_STR` is read by exactly those three services and nothing else on the
box.** That makes "no nsl.sh" an uninstall rather than a flag — the cleanest opt-out on the
whole list, and the only one where stack presence does the work.

Three things the split does **not** solve, all of which still need doing:

1. **`DOMAIN` has to come from somewhere.** It is load-bearing far past routing:
   `ensure-authelia.sh` and `ensure-dex.sh` both refuse to render without it, and it feeds
   AppShield's `REDIRECT_HOST_SUFFIXES`, Caddy's `PCS_EMAIL`, and Authelia's sender address.
   Today an empty `DOMAIN` means no working auth stack, not merely no public URL. The split
   names the provider contract — *set `DOMAIN`, obtain a certificate into `router/certs/`* —
   but no no-provider fallback mode exists.
2. **The control plane is still polled.** `ensure-yundera-user-data.sh` is host layer: it
   refetches `DOMAIN` / `EMAIL` / `UID` / `PROVIDER_STR` / `USER_JWT` on every tick and
   `exit 1`s when `USER_JWT` is absent. The split explicitly keeps `scripts/` in the host
   layer, so a fully opted-out box keeps phoning home. **This needs its own flag regardless
   of the split** — it is the general rule at the top of this document in its clearest form.
3. **Ordering.** The split schedules `nsl-provider` in step 5 of six, after `accounts` — the
   highest-data-risk step. If nsl opt-out is the driver for onboarding, that ordering is
   worth revisiting.

---

### Mail — the coupling to warn about

> **Folding `smtp` into `nsl-provider` makes "no nsl.sh" silently mean "no password reset
> for any app on the box."**

`mail-gateway` is provider-mode only. Its source reads exactly three variables —
`SMTP_PORT`, `RELAY_CREDENTIAL`, `RELAY_ENDPOINT_URL` — and relays through the
mesh-router-backend that owns this PCS's domain. **There is no BYO-SMTP mode.**

What depends on it: Authelia's password reset (the PCS login itself) and every store app
that mails its users — Vaultwarden's reset being the obvious one.

`stack-split.md` is architecturally right that mail *is* an nsl.sh service. But bundling
makes the two choices inseparable, and this is the worst kind of coupling to discover after
opting out. Two ways out, and a reason to prefer the second:

- keep the fold, and give `router/` a BYO-SMTP slot; or
- **give mail its own folder with two modes** (provider relay / user's own relay).

The second also recovers something the split gave up: mail was originally scoped as a sixth
folder — *"zero mounted volumes, a pure-env rehearsal of the whole pattern"* — and folding
it in removed that rehearsal. Since `accounts` is the highest-data-risk step in the plan,
proving the store-update path on something trivial first is worth having. **Unbundling mail
gets the safe pilot and the unbundled choice at the same time.**

---

### Automated app updates — the feature does not exist

Maison has `CheckUpdate` and `ApplyUpdate` (`internal/installer/update.go`) but **no
scheduler**, so there is nothing to toggle. The flag ships with the feature, not before it.

When it is built:

- `internal/backup/schedule.go` is a working scheduler precedent in the same codebase.
- `usersettings.Settings` is the right home — this is a Maison preference, not a host flag.
- **It must be a `*bool`, not a `bool`.** `merge` treats a zero value as "not supplied", so
  a plain bool could be turned on and then never off again. `MetricsHistory` carries exactly
  this comment and exactly this pointer for exactly this reason.
- Per-app override belongs beside the app's update reference, not in global settings.

---

## "Opt out of everything"

**A preset that writes the individual flags — not a mode of its own.**

One source of truth per subsystem, so the wizard can render a mixed state honestly instead
of a global switch that lies once the user changes one thing underneath it. Implementation
is `onboarding.sh run` calling each `feature-*.sh disable` in turn, which is exactly the
extension point that script's own comments invite:

> *Everything else a deployment might want — seeding apps, registering a domain, writing
> operator config — belongs in an override.*

While three of the seven are real, the preset is closer to "opt out of what we can currently
opt out of". Word it accordingly, or hold it until the list is longer.

---

## Two insights worth keeping

### There are two write points, not one

Some of these are decided **before the box exists** and some **on the box**, and trying to
put all of them in one place is where this design goes wrong.

| Decided at | By | Options |
|---|---|---|
| Provisioning | dashboard → orchestrator, which stages `.pcs.env` | domain, support key — they affect what gets built |
| On-box onboarding | the wizard | login, updates, and later sslip — reversible at any time |

There is a wrinkle in the first row. The box **already has an nsl.sh domain by the time
onboarding runs**: the orchestrator stages `.pcs.env`, and `ensure-yundera-user-data.sh`
fetches `DOMAIN` before the wizard is ever reachable. So a "no domain" choice in the wizard
must **uninstall `nsl-provider` and fall back**, not "never install it". That is the cleaner
design anyway, and it matches the split's rule that each step ships independently and leaves
a working system.

### Onboarding and the split are circular — break it with two phases

`stack-split.md` leaves onboarding as its open question and proposes that each installed app
declare its own step:

```
GET /setup/status -> { needed: bool, done: bool, title: string, url: string }
```

No `nsl-provider` installed, no domain step — with no conditional anywhere. That is the
right shape, and it is this feature done better than flags can do it. But it assumes the
apps are already installed, while onboarding is what decides. Hence two phases:

- **Phase A** — a pre-install choice screen. The opt-out list in this document lives here.
- **Phase B** — per-app declared steps, for whatever got installed.

`stack-split.md` covers only Phase B.

Worth noting on feasibility: the split's status line says nothing is implemented, but **the
Maison primitives it depends on are all live** at `schema_version: 2` — `hooks`, `folders`,
`secrets`, `variables`, `files`, `init`, `view: system`, `tips`, per-app env injection. The
only piece that exists nowhere is `/setup/status`.

### One unresolved ownership question

After the split, `ensure-yundera-login.sh` writes into `dex/connectors.d/`, which belongs to
`accounts/` — while the feature belongs to `yundera/`. That is a cross-app write, which the
split's own ownership rule forbids:

> *An app may only write state owned by its own containers. Cross-app needs go over HTTP.*

`connectors.d/` is already designed as a drop-in seam, so it is probably fine as a **declared
exception** alongside `certs/`. But it needs naming before someone builds it as a direct
write. `stack-split.md` does not currently mention it.

---

## Recommended scope

Three feature scripts — `feature-support-key.sh`, `feature-yundera-login.sh`,
`feature-platform-updates.sh` — plus the shared `is_claimed` helper in `scripts/library/`,
and the TS modules and API routes mirroring `SupportEnsure.ts` / `api/admin/support-ensure.ts`.

Everything else waits on architecture that is described elsewhere.

**On the wizard itself:** render the full list of seven as *information* — this is what
Yundera does for you, and here is what each part costs you — but put real toggles only on
what works. Greyed-out switches read as broken, and four of them would be. An honest short
list is the better first impression.
