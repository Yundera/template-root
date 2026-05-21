#!/bin/bash
# Verify the SSH-key posture at the end of PCS handover.
#
# Expected end state once a PCS is handed over to its user:
#   - /home/admin/.ssh/authorized_keys  — non-empty: holds the support key
#     installed by ensure-yundera-support-key.sh (API-sourced). This is the
#     orchestrator's only way back into the PCS after handover.
#   - /root/.ssh/authorized_keys        — empty/absent: the create-time
#     bootstrap ("perso") key has been cleared by clear-root-ssh-keys.sh.
#
# This is a final gate, not a fixer: ensure-yundera-support-key.sh installs
# the support key during the self-check pass, and clear-root-ssh-keys.sh
# (run by os-init.sh just before this) drops root's key. If either
# invariant is violated here, something went wrong upstream — fail loud so
# provisioning aborts (os-init.sh runs this under `set -e`) rather than
# shipping a PCS that is either unreachable (no support key) or still
# trusts the bootstrap key (perso key left on root).
#
# Note: at provisioning time .pcs.env is staged by the orchestrator and
# does not opt out of the support key. A deliberate ENSURE_SUPPORT_KEY=false
# at provisioning would leave admin keyless and is correctly rejected here —
# an orchestrator-unreachable PCS should not pass handover.

set -e

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

ADMIN_KEYS="/home/admin/.ssh/authorized_keys"
ROOT_KEYS="/root/.ssh/authorized_keys"
failed=0

if [ -s "$ADMIN_KEYS" ]; then
    echo "✓ $ADMIN_KEYS present and non-empty (support key installed)"
else
    echo "✗ $ADMIN_KEYS missing or empty — support key not installed, PCS would be unreachable"
    failed=1
fi

if [ -s "$ROOT_KEYS" ]; then
    echo "✗ $ROOT_KEYS is non-empty — bootstrap (perso) key not cleared"
    failed=1
else
    echo "✓ $ROOT_KEYS empty/absent — bootstrap key cleared"
fi

if [ "$failed" -ne 0 ]; then
    echo "✗ Handover SSH-key verification FAILED."
    exit 1
fi

echo "✓ Handover SSH-key posture verified."
