#!/bin/bash
# ensure-casaos-stack.sh - Deploy the CasaOS stack (just `casaos` now).
#
# This service used to live in the main `yundera` compose stack. Phase 1 of the
# Maison migration split it into its own project at /DATA/AppData/casaos so that
# retiring CasaOS in phase 3 becomes a stack deletion rather than surgery on the
# yundera compose file. It was joined here by casaos-oidc-bridge, since deleted
# outright — Dex's `casaos` connector went with it and Authelia is the PCS-local
# credential now. See doc/maison-migration.md.
#
# The directory name carries no leading dot, so Maison's managed-app scan of
# /DATA/AppData (which skips any name containing a dot) picks this stack up and tiles
# it. That is deliberate: the infrastructure stacks are meant to be visible.
#
# ORDERING: must run AFTER ensure-user-compose-stack-up.sh.
#   - the `pcs` network is created and owned by the yundera stack; this stack only
#     attaches to it (external: true), so it must already exist;
#   - the yundera stack-up runs `--remove-orphans`, which removes the now-absent
#     casaos container from the `yundera` project. This script immediately
#     recreates it under the `casaos` project. On the single self-check cycle that
#     applies this template version, CasaOS is briefly down between those two
#     steps. The container name is unchanged, so once it is back
#     every http://casaos:8080 reference (and DEFAULT_SERVICE_HOST=casaos) resolves
#     exactly as before.
set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

# The stack used to be deployed to the hidden /DATA/AppData/.casaos. The compose
# project name is pinned by `name: casaos` in the compose file, not by the directory,
# so deploying from the new path adopts the very same project and containers; the old
# directory is then dead weight holding a 600-mode .env full of secrets. Drop it.
rm -rf /DATA/AppData/.casaos

exec "$YND_ROOT/scripts/tools/deploy-stack.sh" casaos /DATA/AppData/casaos
