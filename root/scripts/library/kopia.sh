#!/bin/bash

# Shared facts about kopia, for the two self-check scripts that both need them and must
# not disagree.
#
# It exists because the image is named in more than one place on the host:
# ensure-backup-config.sh runs kopia itself to create and connect the repository, and
# ensure-kopia-stack.sh declares the containers that then serve it — the resident engine
# Maison execs into, and the web UI beside it. Those starting different kopia builds
# against one repository is exactly the format surprise the pin is there to prevent, so
# the pin is stated once.

# MUST match kopia.DefaultImage in Maison (internal/backup/kopia/kopia.go). Never a
# floating tag: an engine that changes under a live repository turns a format surprise
# into a 3am failure.
KOPIA_IMAGE="kopia/kopia:0.23.1"

# Where kopia keeps its repository config, password, credentials and caches. It is
# Maison's BackupEngineDir("kopia") — SHARED_DIR is left unset in the stack, so Maison
# derives the same path. The engine, the UI and Maison all read out of this one
# directory; nothing but ensure-backup-config.sh writes to it.
KOPIA_ENGINE_DIR="/DATA/AppDataShared/backup/kopia"

# kopia_repo_hostname prints the identity snapshots are filed under.
#
# It is written once into repository.config by `repository connect
# --override-hostname/--username` and never rewritten, precisely so it cannot drift.
# The resident engine container has to be created with the same value: kopia files
# snapshots under user@host, and a container disagreeing would open a second lineage
# inside one repository — invisible until a restore comes back empty.
#
# The fallback matches Maison's own (kopia.Provider.hostname): obviously synthetic, so
# a deployment missing its pin is recognisable rather than silently divergent. Maison
# verifies the container against the config before using it either way, so a wrong
# answer here costs a slower backup, never a misfiled one.
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
