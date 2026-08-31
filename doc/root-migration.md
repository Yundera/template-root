# Moving the template root: `casaos/apps/yundera` → `AppData/yundera`

Status: **planned, not implemented.** Companion to [`maison-migration.md`](./maison-migration.md)
(which removed CasaOS) and [`stack-split.md`](./stack-split.md) (which is a later, larger
proposal this does not depend on).

This document covers one change: the template tree stops living under CasaOS's app folder
and moves to Maison's flat layout, alongside the runtime state that is already there.

---

## Where things are today

### Root A — `/DATA/AppData/casaos/apps/yundera/`

The template tree. Written by exactly two things, both targeting Root A only:

1. **Cold provision** — the orchestrator stages `.pcs.env` / `.pcs.secret.env` here
   (`pcs-orchestrator/src/library/provisioning/runHostBootstrap.ts:129-132`), then
   `pcs-init.sh` rsyncs the tree in.
2. **Every self-check** — `ensure-template-sync.sh` runs migrations from the *new* tree,
   then `rsync -a --delete --exclude-from=<new>/.ignore` over the whole directory.

37 scripts hardcode `YND_ROOT="/DATA/AppData/casaos/apps/yundera"` (85 references in all).

### Root B — `/DATA/AppData/yundera/`

Runtime state, deliberately outside the rsync tree — `admin-session-key` was destroyed on
every template update until `2026-08-02-13-move-admin-session-key.sh` moved it here.

```
auth/          Authelia: users_database.yml, db.sqlite, secrets/, oidc/, clients.d/
dex/           dex.db, config.yaml, connectors.d/, clients/
dex-frontend/  rendered Dex theme
data/certs     written by mesh-router-agent, read :ro by mesh-router-caddy
data/caddy/    Caddy state
admin/gate-data/   AppShield gate sessions
perf/data      mesh-router-perf
onboarding/completed
casaos-oidc-bridge/   (stable only — swept by 2026-07-31-15-drop-casaos-oidc.sh)
.provisioning-in-progress
```

Plus three files that are **copies**, written by `ensure-maison-yundera-mirror.sh` so Maison
renders the stack as a managed app: `docker-compose.yml`, `.env`, `.icon.svg`, and the
`.casaos-mirror` marker.

### Why move

Root B is already the app-folder shape Maison expects
(`maison/docs/app-model.md`), and it already holds every piece of state that matters.
Root A is the odd one out: a tree nested two levels under Maison's `AppsDir`, kept alive by a
mirror script whose entire job is to paper over that fact. Moving the template makes the
mirror unnecessary and gives the stack the same layout as every other app on the box.

---

## Inventory: what cannot be recomputed

The set is exactly what `root/.ignore` protects — everything else in Root A is
`rsync --delete`d and replaced from the template on every cycle.

| Path | Why it survives a template push |
|---|---|
| `.pcs.secret.env` | `USER_JWT`, `PROVIDER_STR`, `DEFAULT_PWD`, `AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, `ADMIN_ASSERTION_SECRET`, `BACKUP_*`. Re-minting breaks pair secrets and signs every session out |
| `.pcs.env` | orchestrator-seeded at provision, then mutated by self-check: `OPERATOR_API`, `UPDATE_URL`, `DEFAULT_SERVICE_HOST/PORT`, `LOCAL_ADMIN_USER`, `ENSURE_SUPPORT_KEY`, `SELF_CHECK_CRON` |
| `.ynd.user.env` | `UID`, `DOMAIN`, `EMAIL`. Refetchable from `${OPERATOR_API}/user/info` — but only with a live `USER_JWT`, so in practice it dies with the secret file |
| `.env` | derived from the three above by `ensure-env-vars-valid.sh` |
| `migration-markers/` | one-shot state. Losing it replays every migration back to 2025-08 |
| `log/*.log` | history, and read by `Health.ts`, `preflight.ts`, `targetSelfCheck.ts`, and `pcs support log` |
| `*.backup` | `env-file-manager.sh` rollback copies |

Two files that per-host state uses but `.ignore` does **not** currently list — fold them in:

- **`.self-check-cron-disabled`** — written to Root A by
  `settings-center-app/.../Migration/steps/stopSource.ts:21`. A template sync landing
  mid-migration deletes it and silently re-enables cron on the source box.
- **`migration-markers/`** is listed, but `run-migrations.sh:47` builds the marker path from a
  hardcoded literal rather than `$YND_ROOT` — it must be handled explicitly at the flip.

---

## Design decisions

### No symlink at Root A

A directory symlink (`casaos/apps/yundera → /DATA/AppData/yundera`) was considered, because it
would let the template flip alone while `settings-center-app` and `pcs-orchestrator` keep
using their hardcoded Root A paths.

**Rejected.** `rm -rf` on the old path is a matter of when, not if, and two of the four forms
someone will plausibly type destroy Root B:

| Command | Result |
|---|---|
| `rm -rf /DATA/AppData/casaos` | safe — `rm` does not traverse a symlinked directory |
| `rm -rf …/casaos/apps/yundera` | safe — unlinks the symlink |
| `rm -rf …/casaos/apps/yundera/` | **Root B's contents deleted** (verified; GNU `rm` does not refuse the trailing slash) |
| `rm -rf …/casaos/apps/yundera/*` | **Root B's contents deleted** |

A `[ -L ]` guard inside a migration script does nothing about an operator at a shell. Two real
directories, with Root A left stale, is fail-safe: every one of those commands then deletes a
dead copy and the next self-check rebuilds from Root B.

### Not a hardlink either

`ln` refuses directories outright (`hard link not allowed for directory`). At file level it is
worse than useless: `env-file-manager.sh:87` writes via `mv "$tmp_file" "$env_file"`, an atomic
rename that **replaces the inode**, so a hardlinked (or file-symlinked) `.pcs.env` silently
becomes two divergent files on the first `set`. Verified both ways. This is the same reasoning
already recorded in `ensure-maison-app-mirror.sh` and `ensure-maison-yundera-mirror.sh`
("COPY, NOT HARDLINK").

### Root A is left populated

Cleanup is a separate, much later phase. Until then Root A is a stale but complete copy —
the rollback path is to point `YND_ROOT` back at it.

Note that `rm -rf /DATA/AppData/casaos` is **not** available even then: `apps/` still holds
every store app (`immich`, `vaultwarden`, `filebrowser`, …), and `ensure-maison-app-mirror.sh`
depends on them being there. Moving those out is `maison-migration.md` phase 2, a separate
fleet data migration. The eventual cleanup is surgical, one path at a time.

---

## Changes

### New: `scripts/migrations/2026-XX-XX-XX-move-root-to-maison.sh`

The cutover. Runs from the **new** tree before the rsync, like every migration, and is dated
last so it sorts after the stable-era migrations, which still operate on Root A.

1. Bail out cleanly if Root B already carries the template tree (idempotent re-run).
2. Copy the non-recomputable set A → B: the three env files (preserving mode — `.pcs.secret.env`
   is 600), `.env`, `migration-markers/`, `log/*.log`, `*.backup`, `.self-check-cron-disabled`.
3. Copy `migration-markers/` **before** anything else reads it, so the 12 stable-era migrations
   are not replayed.
4. Seed Root B with the full template tree from `$TEMPLATE_ROOT` — **required**, see the
   cutover sequence below.
5. Place `.icon.svg` (the job `ensure-maison-yundera-mirror.sh` used to do).
6. Remove the now-meaningless `.casaos-mirror` marker.
7. Verify: every file in the inventory exists in B with matching size and mode. Fail loudly
   and leave A untouched if not — a failing migration aborts the sync.
8. Leave Root A entirely alone.

### `root/.ignore`

Expand from 7 file entries to also protect every runtime path in Root B, so `rsync --delete`
can never reach it:

```
auth/
dex/
dex-frontend/
data/
admin/
perf/
onboarding/
casaos-oidc-bridge/
.provisioning-in-progress
.self-check-cron-disabled
.casaos-mirror
```

rsync excludes are protected from `--delete` (excluded paths are not candidates for deletion
unless `--delete-excluded` is passed, which it is not).

### `scripts/self-check/ensure-template-sync.sh`

- `YND_ROOT` → Root B.
- **Dry-run delete guard.** Before the real sync, run it with `--dry-run --itemize-changes`,
  collect `^\*deleting` lines, and abort if any names a protected path. This converts a
  forgotten `.ignore` entry from silent total loss into a loud refusal:

  ```bash
  rsync -a --delete --dry-run --itemize-changes \
        --exclude-from="$TEMPLATE_ROOT/.ignore" "$TEMPLATE_ROOT/" "$YND_ROOT/" \
    | grep '^\*deleting' > "$DEL_LIST" || true
  if grep -qE 'deleting (auth|dex|dex-frontend|data|admin|perf|onboarding|\.pcs|\.ynd|\.env)' "$DEL_LIST"; then
      echo "✗ REFUSING SYNC: would delete protected state"; cat "$DEL_LIST"; exit 1
  fi
  ```

- **Persistent backup.** Today it does `cp -r "$YND_ROOT" "/tmp/root-backup-$(date +%s)"` and
  restores *only on rsync non-zero exit*, then deletes it on success — so a successful sync that
  removed the wrong subtree leaves no trace, and `/tmp` is cleared on the reboot that follows.
  Move it under `/DATA` and keep the last N.

### `scripts/tools/run-migrations.sh`

Marker directory → Root B, with a bootstrap at the top of the loop:

```bash
if [ ! -d "$MARKER_DIR" ] && [ -d "$OLD_MARKER_DIR" ]; then cp -a "$OLD_MARKER_DIR" "$MARKER_DIR"; fi
```

Without it Root B starts with an empty marker directory and every stable-era migration replays
on every box at once — including `2026-08-02-14-remove-casaos-stack.sh`, which runs
`docker compose down`.

### `scripts/pcs-init.sh`

- `YND_ROOT` → Root B.
- **Relocate the orchestrator-staged seed files.** The orchestrator writes `.pcs.env` and
  `.pcs.secret.env` to Root A before this script runs, and `pcs-init.sh:52` hard-fails without
  them. Move them A → B (preserving mode) before validating. This is what lets the orchestrator
  stay unchanged, and it is the only thing making the flip safe for new provisions —
  `pcs-init.sh` deliberately skips migrations, so nothing else would populate Root B on a fresh
  host.

### `scripts/self-check.sh` and `scripts/self-check-reboot.sh`

`SCRIPT_DIR` is a hardcoded literal in both (`self-check.sh:41`, `self-check-reboot.sh:47`),
not derived from `$YND_ROOT`. Point both at Root B.

### `scripts/self-check/ensure-self-check-at-reboot.sh`

Currently appends the `@reboot` entry when `crontab -l | grep -q "$scriptFile"` misses, and
never removes anything. After the flip `$scriptFile` is the Root B path, so the Root A entry
survives and the box carries **two** `@reboot` self-checks — they race on
`/var/run/yundera-self-check.lock`, the loser exits 0 silently, and Root A's copy never updates
again.

Adopt the marker-comment pattern `ensure-nightly-self-check.sh:40` already uses
(`grep -vF "$MARKER"` then append) so this and any future path move self-heal, and
additionally strip the known-stale Root A entry for boxes that already carry it.

### `scripts/self-check/ensure-maison-yundera-mirror.sh` — delete

Its entire purpose was making Maison see the stack as managed by projecting a copy of the
compose and `.env` into Root B. After the flip those are the real files at the real path, and
`isManaged()` — `stat(/DATA/AppData/<project>/docker-compose.yml)` — is satisfied directly.
Keeping it would copy a stale Root A over the live Root B.

Remove the script, its `scripts-config.txt` entry, and the `.casaos-mirror` marker.

### `scripts/self-check/ensure-maison-app-mirror.sh` — keep

Store apps still live under `/DATA/AppData/casaos/apps/<app>`, and this mirror is what makes
them manageable in Maison. Only its `$YND_ROOT` / `$YUNDERA_ENV` sources move to Root B. It
can go once `maison-migration.md` phase 2 moves each app out of that tree.

### `root/docker-compose.yml`

- `COMPOSE_FOLDER_PATH: "/DATA/AppData/casaos/apps/yundera/"` → Root B.
- `- /DATA/AppData/casaos/apps/yundera/caddy:/etc/caddy:ro` → Root B. Keep it a **directory**
  mount — a single-file bind pins the inode and rsync renames a new file into place, which is
  why `caddy/` is its own directory in the first place.

### Mechanical

The remaining ~30 `YND_ROOT=` literals across `scripts/self-check/`, `scripts/tools/`,
`scripts/migrations/`; `os-init.sh`'s `SCRIPT_DIR`; `dev/docker-compose.yml` and `dev/README.md`;
and the path references in `CLAUDE.md`, `README.MD`, and `doc/`.

---

## Cutover sequence on an existing box

```
cycle N     the OLD ensure-template-sync.sh is what is executing
            → downloads the new tree
            → runs migrations FROM THE NEW TREE, Root A still authoritative
            → the last migration bootstraps Root B (tree + env + markers)
            → the OLD rsync writes the new tree into Root A (harmless)
            → the rest of the cycle runs the NEW scripts (now at Root A),
              which read Root B  ← this is why step 4 of the migration is required:
              ensure-self-check-at-reboot.sh does `chmod +x "$scriptFile"` on the
              Root B path under `set -e`, and would fail on every box otherwise
            → cron repointed to Root B, stale Root A entry stripped

cycle N+1   the NEW ensure-template-sync.sh syncs into Root B.
            Root A is stale from here on.

reboot      @reboot → Root B → self-check rebuilds everything from B's .env
```

**Invariant:** after the flip there is exactly one place the env files live, both cron entry
points reach it, and a `rm -rf` anywhere under `casaos/` destroys only a stale copy.

The invariant's one exception is worth stating: self-check rebuilds all *infrastructure* from
the env files, but **not** `auth/` — `ensure-authelia.sh` re-seeds a lost `users_database.yml`
as `disabled: true`, i.e. unclaimed. That state is unique to Root B and predates this change;
the `.ignore` expansion and the dry-run guard above are what protect it.

---

## Rollout

**Purge jsDelivr immediately after the push.** `runHostBootstrap.ts` fetches `pcs-init.sh` from
jsDelivr pinned to the branch the host self-syncs against, and jsDelivr caches for 12h. A new
host that gets the *old* cached `pcs-init.sh` alongside the *new* template zip rsyncs the tree
to Root A, then hands off to a `self-check-reboot.sh` that reads a Root B nothing populated —
because `pcs-init.sh` skips migrations on first install. Broken provisions until the cache
expires. This is a hard requirement of the deploy, not housekeeping.

Test path is stable → latest in one hop, exercised in `dev/` and then on the test PCS boxes
(holyhorse, wisera, watch) before the fleet.

---

## Out of scope

- **Store apps.** `/DATA/AppData/casaos/apps/<app>` is untouched; moving those is
  `maison-migration.md` phase 2.
- **Deleting Root A.** A later phase, surgical, one path at a time.
- **`stack-split.md`.** Independent proposal; this change neither blocks nor advances it,
  though it does deliver that document's step 3 ("kill the mirror; make
  `/DATA/AppData/yundera/` a real app folder") as a side effect.

## Other packages

Neither is required for this push; see the orchestrator/admin-app notes for detail.

- **`pcs-orchestrator`** — `pcs support` derives four absolute paths from a hardcoded Root A
  (`src/scripts/support.ts:76`); the `USER_JWT` rotation becomes a silent no-op after the flip.
  `HOST_BOOTSTRAP_REMOTE_FOLDER` needs no change, because `pcs-init.sh` relocates the seed files.
- **`settings-center-app`** — ~15 hardcoded Root A literals. Until it ships a resolver, the
  Health panel shows a frozen log and the support toggle writes to a dead `.pcs.env`.
