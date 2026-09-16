# Splitting the template tree out of the stack root

Status: **implemented 2026-09-16.** Companion to [`root-migration.md`](./root-migration.md),
which created the problem this solves.

## The problem

`root-migration.md` moved the template tree from `/DATA/AppData/casaos/apps/yundera/` into
`/DATA/AppData/yundera/`, so the stack would have the app-folder shape Maison expects and the
mirror script could die. It succeeded at that, and it put `rsync -a --delete` and the owner's
Authelia database in the same directory.

Everything after that was mitigation for that one fact:

- `root/.ignore` became load-bearing in a way an exclude list should never be — a dropped line
  was fleet-wide data loss, not a stale file.
- `ensure-template-sync.sh` grew a `PROTECTED_RE` delete guard as a second opinion on `.ignore`.
- Both needed hand-keeping in lockstep, and nothing checked that they agreed.

The guard could not be a second opinion, because its two halves came from different releases:
`.ignore` is read from the template just downloaded, `PROTECTED_RE` from the copy of the script
already on disk. Retiring `.casaos-mirror` from both in one commit (`a6bcc61`) therefore
**deadlocked** every box carrying that marker — new `.ignore` listed it for deletion, old regex
protected it, refuse; and since the refusal is what stops the sync, the box could never receive
the script that would have fixed it. Manual `rm` on each box. Seen on wisera, 2026-09-16, and
the guard was removed the same day (`cbac878`).

## The change

Two roots instead of one:

| Path | Contents | `--delete` target? |
|---|---|---|
| `/DATA/AppData/yundera/` | state: `auth/ dex/ dex-frontend/ data/ admin/ onboarding*/ log/ migration-markers/ .pcs*.env`, plus `docker-compose.yml` and `.icon.svg` for Maison | **never** |
| `/DATA/AppData/yundera/template/` | the template tree, and nothing else | yes — it holds no state |

`ensure-template-sync.sh` is now three commands:

```bash
rsync -a --delete "$SRC_TEMPLATE/" "$YND_TEMPLATE/"
rsync -a "$TEMPLATE_ROOT/docker-compose.yml" "$YND_ROOT/"
rsync -a "$TEMPLATE_ROOT/icon.svg" "$YND_ROOT/.icon.svg"
```

`--delete` is scoped to a directory whose contents this script wholly owns. That is a property
of the layout, not of a list somebody maintains correctly — so `.ignore`, `PROTECTED_RE`, and
the lockstep between them all stop being load-bearing at once.

Two smaller wins fall out. `auth/configuration.yml.tmpl` and `dex.config.yaml.tmpl` move under
`template/`, which retires the `+ /auth/configuration.yml.tmpl` include and the `/auth/**`
descent subtlety. And a failed sync now restores only `template/` instead of rolling the whole
root back over state written since the backup was taken.

## Crossover: two cycles, per box, automatic

A self-updating tree cannot relocate itself in one step — the script performing the sync is the
previous release's copy, and the cron entry that fires next was written by the previous
release's `ensure-nightly-self-check.sh`.

**Cycle N.** The old on-disk script downloads the new tree. Migrations run from the top-level
compatibility shim; `2026-09-16-10-adopt-template-subtree.always.sh` refreshes
`$YND_ROOT/scripts/` in place from `template/scripts/`. The old script's whole-root rsync then
delivers `template/`, leaving the legacy tree alone (the `.ignore` crossover block excludes it).
The remaining steps of this same run are now post-split scripts, so
`ensure-self-check-at-reboot.sh` and `ensure-nightly-self-check.sh` — at steps 13 and 14, i.e.
*after* the sync at step 5 — write cron entries pointing into `template/`.

**Cycle N+1.** Cron runs `template/scripts/self-check.sh`. The new sync script takes over. The
legacy tree is inert.

Roughly two nights, or one if the box reboots. Both cycles exit green, no operator action, no
window in which a box is unmanaged.

> **Why the migration does not flip cron itself.** It is tempting, and it does not work: the
> stale `ensure-nightly-self-check.sh` at step 14 rewrites its own marker-managed entry every
> tick, so a flip performed at step 5 is silently undone eight steps later in the same run.
> Replacing the script tree lets cron converge through the mechanism that already owns it.

> **Why `.always.sh` and not a marker migration.** `run-migrations.sh` writes the marker itself
> for any migration exiting 0, so the "defer the marker to the next cycle" pattern used by
> `2026-09-14-10-move-root-backups-off-data.sh` is already defeated and the fleet carries that
> false marker. `.always.sh` is the suffix the runner exempts; the migration's own guard makes
> it a no-op once a box has crossed.

## The compatibility surface is permanent

Three things exist solely so a **pre-split** box can cross: the crossover block in
`root/.ignore`, the two-file shim at `root/scripts/` (see its `README.MD`), and the
`.always.sh` migration.

**Do not schedule their removal.** There is no safe date. A box on `UPDATE_URL=frozen`, one
powered off, or one built from an old image can arrive months from now still pre-split; if it
downloads a tree with no `.ignore`, its old script hits
`[ ! -f "$TEMPLATE_ROOT/.ignore" ] && exit 1`, fails its sync, and never updates again —
silently, because the self-check completion signal does not distinguish "refused" from "never
ran". The `.casaos-mirror` deadlock is what tidying away a cross-release compatibility surface
actually costs. Keeping it costs three inert files no post-split box reads.

## Deploy

**No sequencing.** One merge, one `stable` cut, nothing timed.

`pcs-orchestrator` derives the `pcs-init.sh` URL from the template branch and had it
hardcoded as `root/scripts/pcs-init.sh`; that path is now `root/template/scripts/pcs-init.sh`.
Rather than order the two repos, `derivePcsInitUrls` returns **both** candidates and
`fetchPcsInitToTmp` takes the first that returns a script. Either repo can ship first. An
explicit `YPM_PCS_INIT_URL` override is still used exactly as given, with no probing.

**Rollback is not symmetric.** Once a box has crossed over, pointing `stable` back at a
pre-split commit leaves it downloading a tree with no `template/`, and the new script refuses:
`✗ Downloaded tree has no template/ directory`. Loud and non-destructive — the box keeps
running, it just stops updating. The recovery move here is roll-forward, not roll-back.

## Verification

A crossover cycle was simulated against a fixture box built from `cbac878` carrying live state
(`users_database.yml`, `db.sqlite`, `dex.db`, `key.pem`, gate sessions, the three env files,
markers, rotated logs) before release. It caught one defect that would have deadlocked the
fleet: `+ /auth/configuration.yml.tmpl` made that file a deletion candidate once it moved under
`template/`, and `auth` is the first alternative in the old `PROTECTED_RE` — so every box that
had not yet received `cbac878` would have refused, permanently. The include was removed; see
the note in `root/.ignore`.

### wisera, 2026-09-16 — the crossover that found the exec-bit bug

The first real crossover ran on wisera against `main`. The sync itself succeeded and the
migration did its job, then every step afterwards failed with exit 126:

```
/DATA/AppData/yundera/template/scripts/tools/env-file-manager.sh: Permission denied
```

Zero of the 62 scripts under `template/scripts` were executable. The old on-disk script sets
exec bits with `find "$TEMPLATE_ROOT/scripts" ...`, which post-split is the **compatibility
shim**, not the template tree; its closing chmod then sweeps `$YND_ROOT/scripts`, the legacy
tree, missing them again. The tree arrived mode 644.

**This does not heal itself.** `execute_script_with_logging` (`library/log.sh`) refuses a
non-executable script — `[ ! -x "$script_path" ] && return 1` — instead of invoking it through
bash. So on every later cycle `ensure-script-executable.sh`, which exists to repair exactly
this, cannot run; and neither can `ensure-template-sync.sh`, so no corrected template can ever
land. Self-locking and fleet-wide, the same shape as the `.casaos-mirror` deadlock. wisera was
repaired by hand (`chmod +x`), after which the next cycle completed clean and cron flipped to
`template/scripts/`.

Two fixes, both shipped:

1. **The migration sets exec bits on the SOURCE**, unconditionally and ahead of its own guard.
   It runs before the old script's rsync, and `rsync -a` preserves modes, so this is the only
   available hook — the script with the wrong `find` is already on the box, a release behind.
2. **`self-check.sh` and `self-check-reboot.sh` chmod `$SCRIPT_DIR` before the first
   `execute_script_with_logging` call**, closing the bootstrap paradox in general: any future
   delivery that loses modes now self-heals rather than bricking the box.

Verified by replaying a crossover with the archive forced to mode 644 — 0/62 executable
reproduced, 62/62 after the fix, including `ensure-template-sync.sh`,
`ensure-script-executable.sh` and the cron target.

### Still unverified

The wisera run covered cron rewriting, the compose restart against the moved `caddy` bind, and
Dex/Authelia rendering from the moved templates — all green, stack healthy, Maison still
rendering the tile from `.icon.svg`. What it did **not** cover is a crossover with the exec-bit
fix in place from the start: wisera crossed before the fix existed and was repaired by hand. A
clean end-to-end crossover on a still-pre-split box (holyhorse) is worth doing before `stable`.
