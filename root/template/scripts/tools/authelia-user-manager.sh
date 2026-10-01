#!/bin/bash
# authelia-user-manager.sh - wrapper: the local accounts belong to the mesh template.
#
# The real script is /DATA/AppData/mesh/scripts/tools/authelia-user-manager.sh
# (list, claim, add, delete, set-password, set-email; JSON on stdout). This path
# is kept because it is the one every Yundera doc, runbook and support session
# names. Same arguments, same stdin, same output and exit codes.
MESH_TOOL="/DATA/AppData/mesh/scripts/tools/authelia-user-manager.sh"
if [ ! -f "$MESH_TOOL" ]; then
    echo "ERROR: the mesh template is not installed ($MESH_TOOL is missing)" >&2
    exit 1
fi
exec bash "$MESH_TOOL" "$@"
