# Backups on by default — the engine latch and the schedule default

Status: **findings + proposal, nothing implemented.** Written 2026-09-04, to be picked up
Monday. The two code changes proposed here land in the **Maison** repo
(`packages/maison`), not in this one; this document lives here because the provisioning
half of the flow — the scripts that create the repository in the first place — is
template-root's, and because the question "why is a provisioned box still writing backups
to local disk?" is asked of the host side first.

Companion to Maison's [`docs/backup.md`](../../maison/docs/backup.md), which specifies the
engine seam, and to its `internal/backupconfig/` package doc, which explains the layering
this proposal extends.

---

## The symptom

On a provisioned PCS the backup settings page shows **"Yundera Backup Storage —
connected"**, with credentials, a repository and a device identity — and the **active
engine is still `local`**, writing archives to `/DATA/AppData/.backups/` on the same disk
it is meant to be protecting. The nightly schedule is off as well, so on most boxes nothing
is running at all.

Two independent causes. Neither is a provisioning failure: the host side does its job.

---

## What the host already does, by default

Three self-check scripts, in this order (`scripts/self-check/scripts-config.txt`, the
"Backup" block, after `ensure-user-compose-stack-up.sh` and before
`ensure-maison-stack.sh`):

| Script | Writes |
|---|---|
| `ensure-backup-credentials.sh` | `.pcs.secret.env`: `BACKUP_DEVICE_ID`, `BACKUP_ENDPOINT`, `BACKUP_BUCKET`, `BACKUP_PREFIX`, `BACKUP_ACCESS_KEY_ID`, `BACKUP_SECRET_ACCESS_KEY`, `BACKUP_EXPIRES_AT`, `BACKUP_WRITABLE`, `BACKUP_STATUS` |
| `ensure-backup-config.sh` | `/DATA/AppDataShared/backup/kopia/`: `repository.config` (once), `repository.password` (once), `credentials.env` (per rotation), `state.json` (per run), `needs-credentials` / `needs-recovery` markers |
| `ensure-kopia-stack.sh` | `/DATA/AppData/kopia/{docker-compose.yml,.env}`; brings up `kopia-engine` (Maison's `docker exec` target) and the kopia UI behind an AppShield gate |

The single knob for all three is **`BACKUP_ENABLED` in `.pcs.env`, and absent means
enabled** — it is an opt-out, for boxes like the demo instance. Nothing in the orchestrator
sets it today.

So the provider is provisioned by default. What is not configured by default is Maison.

---

## The config flow, cold provision

```
pcs-orchestrator ─ runHostBootstrap.ts:119
  └─► /DATA/AppData/yundera/.pcs.env          OPERATOR_API, (BACKUP_ENABLED if set)
      /DATA/AppData/yundera/.pcs.secret.env   USER_JWT   ◄── present from minute 0
  └─► fetches pcs-init.sh (jsDelivr) → hands off to template-root

self-check.sh — scripts-config.txt order, then @reboot + nightly
  │
  ├─ ensure-yundera-user-data.sh   → .pcs.secret.env : USER_JWT (refreshed)
  │                                  .ynd.user.env   : DOMAIN, UID
  ├─ ensure-env-vars-valid.sh      → .env (unified)
  ├─ ensure-user-compose-stack-up.sh   yundera stack up (caddy, dex, smtp, …)
  │
  ├─ ensure-backup-credentials.sh
  │     reads  USER_JWT, OPERATOR_API
  │     calls  GET {OPERATOR_API}/user/backup/space?deviceId=…
  │     writes BACKUP_* → .pcs.secret.env
  ├─ ensure-backup-config.sh
  │     reads  BACKUP_*
  │     runs   kopia repository create | connect   (identity pinned to BACKUP_DEVICE_ID)
  │     writes → /DATA/AppDataShared/backup/kopia/{repository.config,repository.password,
  │                                                credentials.env,state.json}
  ├─ ensure-kopia-stack.sh         → kopia-engine + kopia UI
  │
  └─ ensure-maison-stack.sh
        → /DATA/AppData/maison/{docker-compose.yml,.env}   (deploy-stack.sh)
        → /DATA/AppData/maison/.env.app
        → docker compose up -d        ◄── MAISON STARTS HERE

maison-app
  boot ─ backupconfig.New("/DATA/AppData/maison/backup.json")
       │   missing → seeds the literal  {}   ("this box has no opinion about anything")
       └─ buildEngines → applyChosenEngine        ◄── RUNS ONCE, NEVER AGAIN
             reads backup.json "engine"
             probes kopia: repository.config + state.json, `repository status` in kopia-engine
```

**The only host→Maison channel is `state.json`** — the host writes it, Maison reads it
(display label "Yundera Backup Storage", `writable`, `status`, `credentialExpiresAt`).
`backup.json` has exactly one writer, Maison itself, on `PUT /api/backup/config`. That
one-writer rule is deliberate and load-bearing: the nightly self-check re-renders its side
every night, so any field the two sides shared would be a field the script silently
reverts.

---

## Which field selects the engine, and what "unset" means

`/DATA/AppData/maison/backup.json` → **`engine`** (`backupconfig.Config.Engine`,
`json:"engine,omitempty"`).

```
backup.json "engine"
   │
   ├── non-empty ──►  that engine, hard override, forever
   │                  (an unknown id is a 400, never a silent fallback)
   │
   └── ""/absent ──►  "local"   ← compiled default: backup.New(local, kopia),
                       │          first registered is the writer
                       └── promoted to "kopia" IF kopia probes Connected
                           AT THAT INSTANT — process start only
```

There is no provisioned default-engine field anywhere on the host side.
`backupconfig.Provisioned` exists in the code (`internal/backupconfig/engine.go:120`) with
`Source` and `Locked` support, but **nothing populates it** — it covers retention only, and
not `Engine` or `Enabled`.

---

## Cause 1 — the writer is latched at boot

`applyChosenEngine` has two callers and no others: `buildEngines` at process start
(`internal/server/server.go:129`) and a settings `PUT`
(`internal/server/backupengine.go:218`). Nothing re-evaluates it in between.

Meanwhile `handleBackupStatus` probes kopia **live** on every page load (30s cache) and
reads the label from the host's `state.json`. Hence the exact symptom: the page reports the
provider as connected because that read is fresh, while `active` reports a decision taken
at boot.

Every box whose repository appeared *after* its Maison process started is stuck on `local`
until the container is recreated or someone presses Save on the settings page. For the
existing fleet that is all of them — the backup scripts landed long after those boxes
booted, and `maison-app` only recreates on an image bump.

**Fix:** re-run `applyChosenEngine` where the answer can have changed rather than once at
boot. `Set.SetWriter` is mutex-guarded and `kopia.Status` is 30s-cached, so the cheap
correct spots are the top of `Scheduler.RunAll` and `handleBackupStatus`. A box whose
repository is provisioned at 03:01 then uses it the same night, and opening the settings
page shows reality rather than history. (A ticker also works; it just costs a probe on an
idle box.)

---

## Cause 2 — the schedule is off by default

`backupconfig.Defaults()` has `Enabled: false`
(`internal/backupconfig/backupconfig.go:114`), and that flag is the only gate on the
scheduler (`internal/backup/schedule.go:621` and `:636`). Manual runs ignore it. Everything
else already defaults sensibly: `UserData: true`, 03:30 with per-box jitter, smart
retention.

It cannot simply be flipped to `true`, because a plain `bool` cannot distinguish "the user
turned it off" from "nobody has decided" — and flipping it would also start nightly
*local-engine* backups on boxes with no repository, which stop every container on the box
to archive it onto the same disk.

**Fix:** make it `Enabled *bool` — the tri-state pattern already used by
`usersettings.HistoryEnabled` (`internal/usersettings/usersettings.go:247`) — with unset
resolving to *on when the active writer is offsite and connected*. An explicit user choice,
`true` or `false`, wins forever. A self-hoster on the local engine never gets nightly
app-stopping backups they did not ask for.

The two fixes compose: with cause 1 fixed, a box turns its own schedule on the moment the
host finishes provisioning the space.

---

## Rejected: pre-seeding `backup.json` from PCS init

The obvious-looking alternative — have a self-check script write
`{"engine":"kopia","enabled":true}` into `/DATA/AppData/maison/backup.json`, plus a one-shot
migration for boxes that lack it — was considered and should not be done:

- **It breaks the one-writer rule.** Maison replaces that file wholesale through a
  temporary, under a mutex. A host script writing it concurrently can clobber a user's save,
  and there is no merge to fall back on.
- **It converts a provisioned default into a user override.** `engine` is the field that
  means "the user chose this, do not infer". Writing it from the host makes "reset to
  default" impossible to express, and pins a box that later has no repository to an engine
  with nothing to write to — a state the UI already has a warning for.
- **It does not generalise.** A self-hosted Maison, or a box whose credential call fails on
  the first cycle, still needs the inference.

If the deployment should ever state this explicitly rather than have Maison infer it, the
sanctioned channel is **`state.json`**: add a field in `ensure-backup-config.sh` (the block
at line 216) and populate `backupconfig.Provisioned` from it. That is the seam
`engine.go` was designed for, and `.pcs.env` stays in control through `BACKUP_ENABLED`.

With cause 1 fixed, neither is necessary.

---

## Open question for Monday — the legacy `enabled: false`

A box where someone once pressed Save on the settings page with an older Maison has a
literal `"enabled": false` in `backup.json`, written by a UI where the checkbox merely
*defaulted* to off. Under the new tri-state that decodes as a deliberate "the user turned
it off", and the box stays dark.

Proposal: at load time inside `backupconfig` (never from a host script), treat a legacy
file — one with no schema marker — carrying `enabled:false` as **unset**. It costs one box,
once, where somebody genuinely meant off; it saves every box where nobody ever decided. A
box with the seeded `{}` needs nothing either way.

**Decision needed before implementing.**

---

## Field notes, 2026-09-04

Two boxes read while diagnosing this. Both carry a hand-saved
`{"enabled": true, "engine": "kopia", …}` with the empty `smtp` block an older Maison
emitted, so both are outside the population the migration question is about.

- **holyhorse** (`185.216.75.105`) — `/DATA/AppDataShared/backup/kopia/` holds a
  **`needs-recovery`** marker and **no `repository.config` or `repository.password`**. The
  backup space already held a repository and this box has no password, so
  `ensure-backup-config.sh` correctly refused to initialise a second one under the same
  prefix. Its `backup.json` says kopia + enabled, so the box believes it is backing up and
  is not. This is the rebuilt-box case; recovery mode is not built.
- **yunderalabs** (`194.163.132.224`) — a **`needs-credentials`** marker written at 03:01
  that morning: the storage refused its key. That is the designed path (the next cycle
  re-mints), but worth confirming it cleared.

Neither is caused by the two issues above, and both are worth a separate look.

---

## Where the work lands

1. `packages/maison` — both fixes, plus the legacy-`enabled` read once decided. Tests exist
   for `backupconfig` and the scheduler; extend rather than add a new suite.
2. Tag Maison (GitHub Action publishes `ghcr.io/yundera/maison` on `v*`), then bump the pin
   in **this** repo: `root/stacks/maison/docker-compose.yml` (`ghcr.io/yundera/maison:1.1.24`
   at the time of writing).
3. No template-root script changes are required by the proposal as it stands. If the
   `state.json` route is chosen instead, `ensure-backup-config.sh` gains one field.
