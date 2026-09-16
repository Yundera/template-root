# Compatibility shim — not part of the template tree

Everything the template ships lives in `../template/`. This directory exists for
exactly one reason, and it is never installed on a box.

A self-updating tree cannot relocate itself in a single step. The script that
performs a sync is the copy already on disk, so a box still on the pre-split
layout runs the **old** `ensure-template-sync.sh`, and that script looks for
migrations at `<downloaded tree>/scripts/migrations` with a runner at
`<downloaded tree>/scripts/tools/run-migrations.sh`. If it does not find them it
prints "Skipping migrations", exits 0, and the box never crosses over — forever,
on every subsequent cycle.

So those two paths are reproduced here, and nothing else:

| File | Why |
|---|---|
| `migrations/2026-09-16-10-adopt-template-subtree.always.sh` | the handover itself — copy of `../template/scripts/migrations/<same>` |
| `tools/run-migrations.sh` | the runner the old script invokes — copy of `../template/scripts/tools/<same>` |

**Keep both byte-identical to their `../template/` originals.** They are copies
rather than symlinks because a symlink's survival through GitHub's zipball and
`unzip` is not something worth betting a fleet on.

`root/.ignore` excludes `/scripts/`, so the old sync never delivers this
directory to a box; it only ever reads it out of the downloaded archive. A
post-split box does not look at it at all — `ensure-template-sync.sh` reads
migrations from `template/scripts/migrations/`.

## Lifetime: permanent

The obvious follow-up is a release that deletes this directory and the R2 block
in `root/.ignore` once the fleet has crossed over. **Do not schedule one.**

There is no safe date. A box on `UPDATE_URL=frozen`, one that has been powered
off, or one built from an old image can arrive here months later still on the
pre-split layout. If it downloads a tree with no `.ignore`, its old on-disk
script hits `[ ! -f "$TEMPLATE_ROOT/.ignore" ] && exit 1`, fails its sync, and
never updates again — silently, with no remote recovery path, because the
self-check completion signal does not distinguish "refused" from "never ran".

The cost of keeping this is three inert files that no post-split box ever reads.
That is a good trade for an escape hatch with no expiry date.
