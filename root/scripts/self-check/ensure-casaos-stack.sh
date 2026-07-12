#!/bin/bash
# ensure-casaos-stack.sh - Deploy the CasaOS stack (casaos + casaos-oidc-bridge).
#
# These two services used to live in the main `yundera` compose stack. Phase 1 of
# the CasaDash migration split them into their own project at /DATA/AppData/.casaos
# so that retiring CasaOS in phase 3 becomes a stack deletion rather than surgery on
# the yundera compose file. See doc/casadash-migration.md.
#
# ORDERING: must run AFTER ensure-user-compose-stack-up.sh.
#   - the `pcs` network is created and owned by the yundera stack; this stack only
#     attaches to it (external: true), so it must already exist;
#   - the yundera stack-up runs `--remove-orphans`, which removes the now-absent
#     casaos / casaos-oidc-bridge containers from the `yundera` project. This script
#     immediately recreates them under the `casaos` project. On the single
#     self-check cycle that applies this template version, CasaOS is briefly down
#     between those two steps. Container names are unchanged, so once it is back
#     every http://casaos:8080 reference (and DEFAULT_SERVICE_HOST=casaos) resolves
#     exactly as before.
set -euo pipefail

YND_ROOT="/DATA/AppData/casaos/apps/yundera"

exec "$YND_ROOT/scripts/tools/deploy-stack.sh" casaos /DATA/AppData/.casaos
