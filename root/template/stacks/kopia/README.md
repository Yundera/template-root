# kopia stack

The box's backup engine and kopia's own web UI. Maison owns the schedule and the
app-level backup/restore. It does the work by `docker exec`-ing into **kopia-engine**,
a resident container from this stack. **kopia-app** is kopia's upstream UI (browse
snapshots, restore a single file, retention, task log), reachable only through the
**kopia** AppShield gate.

| Host | Serves |
|---|---|
| `kopia-${DOMAIN}` | the gate → kopia's web UI (also the Maison **Kopia** tile) |

Also answers on the `-${PUBLIC_IP_DASH}.nip.io` and `.sslip.io` variants.

Deployed to `/DATA/AppData/kopia` (project name `kopia`) by `ensure-kopia-stack.sh`.
This README is copied there on every deploy.

## Services

| Container | Image | Networks | Role |
|---|---|---|---|
| `kopia` | `appshield` | `pcs`, `kopia-engine` | AppShield gate, the only public entrypoint. SSO only, no machine path |
| `kopia-app` | `${ENGINE_IMAGE}` | `kopia-engine` | `kopia server start --ui` on `51515`, unauthenticated, behind the gate |
| `kopia-engine` | `${ENGINE_IMAGE}` | `kopia-engine` | `sleep infinity`. Maison runs `maison-engine` in it per command |

- **The engine is resident** because a `docker run` on a PCS costs 6–7 s of container
  start before kopia begins, against about 1.5 s for a whole `snapshot list`. One
  `snapshot list` went from 13.1 s to 3.0 s. That startup cost is what made the store's
  Install button look dead.
- **The UI and the engine are two containers, not one,** because their lifecycles
  differ. The UI reads its S3 credentials once at start and has to be restarted when
  they rotate. It is also the half with a listening socket. Merging them would let a UI
  restart kill a backup mid-run. Both can open the repository at once (kopia's normal
  desktop setup) and share one cache.
- **One image serves as both, and it is the adapter.** `maison-kopia-engine` is
  kopia's image plus the `maison-engine` binary, which speaks Maison's backup adapter
  protocol. The UI runs `/bin/kopia` from the same image, so the two are on the same
  kopia build by construction. Bumping kopia means changing the adapter's Dockerfile.
- **The tag is pinned in `scripts/library/kopia.sh` (`ENGINE_IMAGE`), not in the
  compose.** Four things need it: both services, the one-shot `docker run` in
  `ensure-backup-config.sh`, and the `image` field of `adapter.json`. A literal in the
  compose would be a second pin, and two pins that disagree run two kopia builds
  against one repository. Keep it pinned; never use a moving tag.
- **Root with five capabilities** (`DAC_READ_SEARCH DAC_OVERRIDE CHOWN FOWNER FSETID`,
  `no-new-privileges`) on both kopia containers. The uid 1000 user cannot read an app's
  private 0700 dirs (postgres' pgdata), and a restore has to put ownership and setuid
  bits back. This mirrors Maison's `engineCaps` and the `engine_run` in
  `ensure-backup-config.sh`, so all three must change together.
- **`--allow-extremely-dangerous-unauthenticated-server-on-the-network`** is accepted
  because the audience is narrowed by the network instead of a password (next section).
  `--enable-actions` must stay absent, since it would turn the UI into a remote shell.

### Only the gate is on `pcs`

`kopia-app` and `kopia-engine` sit on the stack's own bridge, `kopia-engine`. The gate
is the only container on both that bridge and `pcs`. There are two reasons, and either
one alone would be enough:

- auth-registrar derives an OIDC `client_id` from the PTR name of any container on
  `pcs`, so a named container there is a claimable identity. Only the gate may claim
  `kopia`.
- kopia-app is an unauthenticated API that runs as root over all of `/DATA`. On `pcs`,
  every store app could reach it.

That bridge becomes `internal: true` (no egress) when the repository is on a local
filesystem. `ENGINE_NETWORK_INTERNAL` is read from `repository.config`.

The **container names are load-bearing**: the gate must be `kopia`, or it registers
callbacks for a host the caddy labels don't publish, and the backend therefore takes
the `-app` suffix.

## How it is built

Ordered in `scripts/self-check/scripts-config.txt`:

```
ensure-yundera-user-data.sh   USER_JWT (and its rotation)        → .pcs.secret.env

ensure-backup-credentials.sh  GET ${OPERATOR_API}/user/backup/space?deviceId=…
                              (Bearer USER_JWT)                   → BACKUP_* in .stack.env
                              only when absent, within 30 days of expiry,
                              or engine/needs-credentials exists — NOT every night
                              (every run while engine/needs-recovery exists: resetAt)
                              records the space's resetAt as BACKUP_RESET_AT and acts on it

ensure-backup-config.sh       one-shot `docker run ${ENGINE_IMAGE} … --repo-dir=engine/`
                              connect.json         storage params + identity (every run)
                              credentials.env      (rewritten on rotation)
                              repository.password  (minted once, before the first connect)
                              repository.config    `maison-engine connect` — written ONCE, never rewritten
                              state.json           label, space, writable, expiry, recoveryHelpUrl
                              adapter.json         descriptor Maison registers the engine from
                              (needs-recovery: the four above still written, then stop)

ensure-mesh-installed.sh      … Maison's first boot finds a connected repository

ensure-kopia-stack.sh         skip if BACKUP_ENABLED=false (stack taken down) or no repository.config
                              tools/deploy-stack.sh kopia /DATA/AppData/kopia
                                TZ, ENGINE_IMAGE, ENGINE_NETWORK_INTERNAL,
                                KOPIA_HOSTNAME (read from repository.config)
                              restart kopia-app if credentials.env is newer than it
```

Things worth knowing:

- **The credentials call is rationed.** Every call mints a new key and revokes this
  device's previous one, and the server caps mints per device per day (429). A healthy
  box calls about four times a year. All failures are soft (exit 0), so a box with no
  credential shows "not configured" in Maison.
- **Any failed `status` arms `needs-credentials`**, whatever the provider's error text
  was. A false positive costs one extra mint; a false negative (B2's wording for a
  revoked key matched no pattern) meant months with no backups.
- **The credentials are not in `repository.config`.** The adapter blanks the S3 fields
  that kopia persists there and reads `credentials.env` on every invocation. Rotation
  therefore never reconnects, because a reconnect can silently refile snapshots under a
  new `user@host` lineage.
- **The identity is `pcs@<BACKUP_DEVICE_ID>`**, written once into `repository.config`.
  `kopia-engine`'s `hostname:` must equal it (`KOPIA_HOSTNAME`). `kopia-app` needs no
  hostname pin because the server reads the identity from the config.
- **`adapter.json` is written before the reachability probe.** An unreachable repository
  is still this box's destination, and Maison must keep reporting it as unreachable
  rather than silently backing up to local disk. A box in `needs-recovery` gets one too,
  so Maison can offer key entry. Only a box with no repository config that isn't in
  recovery has no descriptor.

### Maison's side

- Maison scans `AppData/*/engine/adapter.json` and registers one engine per file.
  `engineId` must equal the folder name (`kopia`).
- The descriptor names `image`, `container: kopia-engine`, `entrypoint`
  (`/usr/local/bin/maison-engine`), `hostname` and `network` (`none` for a filesystem
  repository).
- `BACKUP_ENGINE_CONTAINER=kopia-engine` is seeded into the mesh `.env`
  (`library/mesh.sh`), and the maison stack reads it.
- Before exec-ing, Maison checks that the container's hostname matches the descriptor.
  When the container is **absent, stopped, paused, restarting or mismatched**, it runs
  a one-shot container of `image` per command: 6–7 s slower, and it reaches the same
  repository under the same identity. A command that **starts in the container and then
  fails** is not run again elsewhere; the backup is recorded as failed. Maison does not
  raise a dedicated incident for an unreachable engine yet (`maison/docs/backup.md`
  marks it as not built).
- `backup.skip: true` in this compose keeps the stack out of every backup, including
  manual ones, since stopping this app to snapshot it would stop the snapshotter.
  Restores of older backups of it still work.

## On disk

```
/DATA/AppData/kopia/
├── docker-compose.yml  .env  .icon.svg  README.md   regenerated every self-check — don't edit
├── .stack.env                     STATE — BACKUP_* (credential + BACKUP_DEVICE_ID +
│                                  BACKUP_RESET_AT, the last reset the box saw), 600.
│                                  Written by ensure-backup-credentials.sh; none of it
│                                  reaches .env (the compose references no BACKUP_*)
├── gate-data/                     the gate's sessions
└── engine/                        0700, owned by PUID; written only by ensure-backup-config.sh
    ├── repository.password        STATE — the ONLY copy on the box. Lose it and every
    │                              snapshot in the bucket is unreadable (unless the user
    │                              was mailed it). Not in any backup.
    ├── repository.config          STATE — identity + storage, written once (S3 keys blanked)
    ├── credentials.env            regenerated from BACKUP_* on rotation (~90 days)
    ├── connect.json               bucket/endpoint/region/prefix/hostname/username, 644, every
    │                              run — what `connect` was given; the adapter's `recover` reads it
    ├── repository.password.candidate  TRANSIENT — a key the user typed into Maison, written by
    │                              Maison (600) for `recover`, removed on every outcome
    ├── state.json  adapter.json   regenerated every run (also in needs-recovery)
    ├── needs-credentials          marker: ask for a new key next cycle
    ├── needs-recovery             marker: bucket holds a repository this box can't open
    ├── repository.*.reset-<stamp> the old config/password, moved aside after a space reset
    ├── cache/                     CACHE — shared by engine, UI and one-shots; safe to delete
    └── logs/cli-logs/             kopia's per-command logs — where the real errors are
```

### Recovery

A rebuilt box whose space already holds a repository gets exit 13 from `connect` and
writes `needs-recovery`. It keeps rotating its credential and writing `connect.json`,
`state.json` and `adapter.json`, so Maison still shows the engine, now flagged as
needing recovery, but it never mints a password or connects. There are two ways out:

- **The user has the key.** They enter it in Maison. Maison writes
  `repository.password.candidate` and runs the adapter's `recover`, which connects with
  `connect.json` (connect only, never create), promotes the candidate to
  `repository.password`, removes the marker and pins the existing snapshots. A wrong
  key exits 14 and changes nothing.
- **The key is lost.** The user resets the space from the dashboard
  (`recoveryHelpUrl`). That revokes every key, empties the prefix and stamps `resetAt`.
  A box in recovery calls `/backup/space` on every run. When `resetAt` is newer than
  the marker's `detectedAt`, it removes the marker, and `ensure-backup-config.sh`
  creates a fresh repository. A box that was healthy notices later, through its revoked
  key (`needs-credentials`). If its recorded `BACKUP_RESET_AT` differs, it moves
  `repository.config` and `repository.password` aside to `.reset-<stamp>` and creates
  a fresh repository too. A box that has never recorded a `resetAt` only records it.

The engine state used to live in `/DATA/AppDataShared/backup/kopia/`.
`ensure-backup-config.sh` moves it here once and never merges the two.

## What it needs from the other stacks

- **yundera stack / provisioning**: `USER_JWT`, `OPERATOR_API` and `BACKUP_ENABLED` (in
  `.pcs.env`, default on, off for the demo box). `BACKUP_*` used to sit in
  `.pcs.secret.env`; both backup self-checks move it into `.stack.env` here, keeping a
  `.pcs.secret.env.<date>.old` copy of the file as it was.
- **mesh template** (`/DATA/AppData/mesh`): the `pcs` network, Caddy routing for
  `kopia-*`, and auth-registrar/Dex for the gate's SSO. That is why this stack deploys
  after `ensure-mesh-installed.sh`.
- **Maison** is the consumer. Nothing in this stack depends on Maison.

## Day-to-day

```bash
S=/DATA/AppData/yundera/template/scripts/self-check
sudo bash $S/ensure-backup-credentials.sh && sudo bash $S/ensure-backup-config.sh
sudo bash $S/ensure-kopia-stack.sh

ls /DATA/AppData/kopia/engine/                       # markers?
sudo cat /DATA/AppData/kopia/engine/adapter.json
sudo docker exec kopia-engine /bin/kopia \
  --config-file=/DATA/AppData/kopia/engine/repository.config snapshot list --all
  # needs KOPIA_PASSWORD + the credentials.env vars in the environment

# the actual error of a failed backup
sudo sh -c 'grep -l "\"errors\":[1-9]\|error reading" /DATA/AppData/kopia/engine/logs/cli-logs/*snapshot-create*.log'
```

## Known traps

| Symptom | Cause |
|---|---|
| No kopia containers, self-check green | `engine/needs-recovery`: a rebuilt box with no password for the existing repository. Maison asks for the emailed key; without it, the user resets the space from the dashboard (see Recovery). Needs adapter 1.1.0+ and a Maison with key entry |
| Stack skipped, "no repository.config yet" | No credentials yet (no `USER_JWT`, API down) or `BACKUP_ENABLED=false` |
| Credentials minted every night | `status` keeps failing, so `needs-credentials` keeps being armed. Check the adapter's detail in the log. Root-owned 0700 dirs in `cache/` read by a non-root run looked exactly like this |
| Maison shows "backup failed" with spinner frames and `N fatal error(s)` | Maison keeps an 8-line tail, and progress output pushes out the `ERROR` line. Read `engine/logs/cli-logs/` |
| `permission denied` reading an app's data dir | The engine isn't running as root with the five caps (stale Maison or drifted caps) |
| UI shows an error page after ~90 days | kopia-app still holds a revoked key. The next `ensure-kopia-stack.sh` restarts it |
| Restore finds no snapshots | A second `user@host` lineage: an engine hostname that doesn't match `repository.config` |

## See also

- `docker-compose.yml`: the full rationale for each setting.
- `scripts/library/kopia.sh`: the pin, the paths, and identity extraction.
- `scripts/self-check/ensure-{backup-credentials,backup-config,kopia-stack}.sh` headers.
- `doc/backup-default-engine.md`, and in Maison `docs/backup.md` (adapter protocol,
  `backup.skip`, the markers).
