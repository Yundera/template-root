#!/bin/bash

# One-shot at handover: disable SSH password authentication for good.
#
# Belt-and-braces with ensure-ssh.sh, which already ships the same settings as
# the drop-in /etc/ssh/sshd_config.d/99-yundera-harden.conf. This one edits the
# main sshd_config so the posture survives a distro that stops sourcing the
# drop-in directory.
#
# NEVER `systemctl restart sshd`. Two reasons, both learned the hard way:
#
#   1. `sshd.service` IS NOT A UNIT on Ubuntu — it is an [Install] Alias of
#      ssh.service, so the symlink only exists while ssh.service is ENABLED.
#      ensure-ssh.sh deliberately runs `systemctl disable ssh.service` on every
#      socket-activated host (24.04 and later), which removes that alias. The
#      restart then dies with "Unit sshd.service not found", this script exits
#      1, os-init.sh's `set -e` aborts, and the whole provisioning run fails
#      with "Remote command exited 1: /root/pcs-init.sh" — observed on
#      demostaging1, 2026-08-23, at the very last step of an otherwise healthy
#      install.
#   2. Under socket activation a restart of ssh.service deletes /run/sshd
#      (RuntimeDirectory=sshd) and can strand the host. See the header of
#      ensure-ssh.sh — that is the 2026-07-14 incident.
#
# So: validate the config, and only nudge a service that is actually running.
# Socket-activated sshd re-reads sshd_config on every connection, so there is
# nothing to reload there at all.

SSH_CONFIG="/etc/ssh/sshd_config"

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Update SSH config to disable password authentication
sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#*ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#*UsePAM yes/UsePAM no/' "$SSH_CONFIG"

# Add explicit settings if they don't exist
if ! grep -q "^PasswordAuthentication no" "$SSH_CONFIG"; then
    echo "PasswordAuthentication no" >> "$SSH_CONFIG"
fi
if ! grep -q "^ChallengeResponseAuthentication no" "$SSH_CONFIG"; then
    echo "ChallengeResponseAuthentication no" >> "$SSH_CONFIG"
fi
if ! grep -q "^UsePAM no" "$SSH_CONFIG"; then
    echo "UsePAM no" >> "$SSH_CONFIG"
fi

# A syntactically broken sshd_config IS worth failing on: the next connection
# would be refused and the support key is the only way back in.
if ! sshd -t 2>/dev/null; then
    echo "ERROR: sshd configuration is invalid after hardening:"
    sshd -t 2>&1 | sed 's/^/    /'
    exit 1
fi

# Apply. Reload (not restart) and only when ssh.service is genuinely running —
# i.e. a traditional non-socket host, or a long-lived activated instance.
if systemctl is-active --quiet ssh.service 2>/dev/null; then
    if systemctl reload ssh.service 2>/dev/null; then
        echo "SSH password authentication has been disabled (ssh.service reloaded)."
    else
        # Not fatal: the config on disk is already correct and valid, so every
        # sshd started from here on honours it. Worst case an existing listener
        # keeps the old policy until the next boot.
        echo "WARN: could not reload ssh.service; config is valid on disk and takes effect on next start."
    fi
else
    echo "SSH password authentication has been disabled (socket-activated sshd reads the config per connection; no reload needed)."
fi

exit 0
