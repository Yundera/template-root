#!/bin/bash

# Shared facts about the backup engine, for the two self-check scripts that both need
# them and must not disagree.
#
# ensure-backup-config.sh runs the engine to create and connect the repository;
# ensure-kopia-stack.sh declares the containers that then serve it. Those starting
# different builds against one repository is exactly the format surprise a pin exists to
# prevent, so the pin is stated once, here.

# THE ENGINE IMAGE. It is the kopia ADAPTER — kopia's own image plus the `maison-engine`
# binary that speaks Maison's backup adapter protocol (see the maison-kopia-engine repo,
# docs/protocol.md).
#
# ONE PIN, NOT TWO, AND THIS LINE IS IT. The stack's compose says `${ENGINE_IMAGE}` on
# both of its engine services and gets the value from here, via deploy-stack.sh.
#
# It is here rather than literally in the compose because FOUR things need it and only two
# of them are compose services:
#   - kopia-app and kopia-engine;
#   - the one-shot `docker run` in ensure-backup-config.sh, which creates and connects the
#     repository BEFORE any container exists, so it cannot exec into one;
#   - the "image" field that script writes into adapter.json.
#
# That last one is load-bearing BECAUSE Maison is engine-agnostic, not in spite of it.
# Maison no longer contains an engine (internal/backup/kopia is gone), so when the
# resident container is unreachable and it falls back to a one-shot it cannot know what
# to run — the descriptor supplies it, and engine.Argv refuses a spec with no image.
#
# Naming the tag literally in the compose as well would make it a second pin. Two pins
# disagreeing does not fail loudly: it runs two different kopia builds against one
# repository, and that is found at restore time.
#
# The image is built FROM a pinned kopia, so the kopia version is an attribute of this
# tag: Maison does not know it, cannot disagree about it, and bumping kopia is a change to
# the adapter's Dockerfile. It serves BOTH containers, `kopia server --ui` included,
# because /bin/kopia is still in there.
#
# PINNED, AND IT HAS TO STAY PINNED. This was `:main` while the adapter was being
# exercised on a test PCS; a moving tag means the engine can change under a live
# repository between two self-check cycles, with nothing in the logs to say it did. Bump
# it deliberately, to a tag that exists, or not at all.
ENGINE_IMAGE="ghcr.io/yundera/maison-kopia-engine:1.0.1"

# The adapter binary inside that image. `docker exec` does not apply an image's own
# ENTRYPOINT, so Maison names this explicitly — and so does this script, which runs the
# adapter one-shot before any container exists.
ENGINE_BINARY="/usr/local/bin/maison-engine"

# The engine's permanent identifier. It is recorded on every backup written under it and
# is how those backups are found again after a user switches engines, so it can never
# change.
#
# IT IS ALSO THE APP FOLDER'S NAME, and since the engine's state moved into that folder
# (below) that is load-bearing rather than tidy: Maison discovers an engine by finding
# adapter.json at AppData/<id>/engine/ and checking the descriptor's engineId against the
# folder it sits in, which is what stops one engine's configuration being read into
# another engine's provider.
ENGINE_ID="kopia"

# Where the engine keeps its repository config, password, credentials and caches.
#
# It lives inside the engine's OWN APP FOLDER, like any other app's data. It used to sit
# apart, in /DATA/AppDataShared/backup/<engine>/, so that it fell inside the user-data
# backup set and each engine's backup carried the other engines' configuration. That
# property was close to circular — reading any backup at all needs the repository
# password, so a box able to use the carried configuration has already recovered without
# it — and it cost a whole directory tree beside AppData plus a carve-out in the
# user-data restore path to stop that tree being rolled back under the running engine.
#
# The engine is an app now, so its state is where an app's state goes, and the tree is
# kept out of backups by the `backup.skip` its stack declares rather than by living
# somewhere backups do not reach.
#
# `engine` is dotless: inside an app folder, dot-prefixed names are Maison's own
# namespace (.env, .seed/, .icon.*, .init/).
#
# It is Maison's BackupEngineDir("kopia") — SHARED_DIR is left unset in the stack, so
# Maison derives the same path. The engine, the UI and Maison all read out of this one
# directory; nothing but ensure-backup-config.sh writes to it.
KOPIA_ENGINE_DIR="/DATA/AppData/$ENGINE_ID/engine"

# The backup credential and the box's device identity (BACKUP_*), written by
# ensure-backup-credentials.sh and read by ensure-backup-config.sh. The kopia stack's
# own state, so it lives in the stack's folder rather than in .pcs.secret.env, which is
# the orchestrator's hand-off file — and the orchestrator never writes these: the box
# fetches them itself. It travels and restores with the stack folder, beside
# engine/repository.password; a box moved with tools/migrate.sh keeps its
# BACKUP_DEVICE_ID, which is right, since the source is retired by the move.
#
# NOT inside engine/. ensure-backup-credentials.sh writes here BEFORE
# ensure-backup-config.sh relocates a legacy engine directory, and that relocation
# `rm -rf`s the legacy tree when it finds engine/ already present — creating engine/
# early would take repository.password with it. The kopia compose never references
# BACKUP_*, so deploy-stack.sh's filter keeps all of it out of the stack's .env.
KOPIA_STACK_ENV="/DATA/AppData/$ENGINE_ID/.stack.env"

# What an older template kept in .pcs.secret.env and kopia_adopt_backup_env moves here.
# BACKUP_ENABLED is not among them: an owner knob, it stays in .pcs.env.
KOPIA_STACK_KEYS="BACKUP_DEVICE_ID BACKUP_SPACE_ID BACKUP_ENDPOINT BACKUP_REGION BACKUP_BUCKET
    BACKUP_PREFIX BACKUP_ACCESS_KEY_ID BACKUP_SECRET_ACCESS_KEY BACKUP_EXPIRES_AT BACKUP_STATUS
    BACKUP_WRITABLE BACKUP_LABEL"

# Move BACKUP_* from .pcs.secret.env into KOPIA_STACK_ENV (library/env.sh,
# stack_env_adopt). Called first by both backup self-checks, so whichever runs first
# on an updated box does the move and neither ever reads the old file. Needs log.sh
# and env.sh sourced.
kopia_adopt_backup_env() {
    # shellcheck disable=SC2086 # word-split on purpose: a list of key names
    stack_env_adopt "/DATA/AppData/yundera/.pcs.secret.env" "$KOPIA_STACK_ENV" $KOPIA_STACK_KEYS
}

# The directory that replaced, read exactly once — by the migration in
# ensure-backup-config.sh, which moves it and then removes it. Nothing else may use it.
KOPIA_LEGACY_ENGINE_DIR="/DATA/AppDataShared/backup/$ENGINE_ID"

# kopia_repo_hostname prints the identity snapshots are filed under.
#
# It is written once into repository.config by `connect` and never rewritten, precisely
# so it cannot drift. The resident engine container has to be created with the same
# value: kopia files snapshots under user@host, and a container disagreeing would open a
# second lineage inside one repository — invisible until a restore comes back empty.
#
# The fallback matches Maison's own: obviously synthetic, so a deployment missing its pin
# is recognisable rather than silently divergent. Maison verifies the container against
# the descriptor before using it either way, so a wrong answer here costs a slower
# invocation, never a misfiled backup.
kopia_repo_hostname() {
    local config="$KOPIA_ENGINE_DIR/repository.config"
    local host=""
    if [ -r "$config" ]; then
        # Plain text extraction: this runs before Maison is up and the host has no
        # guaranteed JSON tooling. The field is written by kopia and is a bare string.
        host="$(sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"
    fi
    if [ -z "$host" ]; then
        host="maison-unpinned"
    fi
    printf '%s' "$host"
}

# kopia_repo_storage_type prints the repository's storage backend ("s3", "filesystem"),
# or nothing when there is no configuration yet.
#
# It decides whether the engine container needs to reach the internet at all. A
# repository on a local filesystem does not, and a container that cannot reach a network
# it has no use for is one fewer thing to reason about.
kopia_repo_storage_type() {
    local config="$KOPIA_ENGINE_DIR/repository.config"
    [ -r "$config" ] || return 0
    sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1
}
