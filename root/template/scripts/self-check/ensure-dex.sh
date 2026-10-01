#!/bin/bash
# ensure-dex.sh - wrapper: Dex is the mesh template's.
#
# NOT a self-check step (it is not in scripts-config.txt): the mesh template
# renders and restarts Dex in its own self-check. This path is kept for callers
# that re-render Dex right after dropping a connector into
# /DATA/AppData/auth/dex/connectors.d/ — the demo's open-entry setup
# (demo/src/lib/DemoManager.ts) calls it by this path. Runs the mesh
# ensure-dex.sh under the mesh self-check's lock (library/mesh.sh).
set -euo pipefail

YND_TEMPLATE="/DATA/AppData/yundera/template"
source "$YND_TEMPLATE/scripts/library/log.sh"
source "$YND_TEMPLATE/scripts/library/mesh.sh"

mesh_run self-check/ensure-dex.sh "$@"
