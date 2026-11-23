#!/bin/bash

# Install and configure OpenSSH server, and keep host SSH converged.
#
# NO `set -e` HERE — DELIBERATELY.
#
# This script is a converger: the nightly self-check is the fleet's only
# self-heal mechanism, and it can only heal what actually executes. `set -e`
# turns "get as far as you can, every night, forever" into "stop at the first
# bump and wait for a human". That is exactly how the 2026-07-14 incident
# became a 10-day outage: `systemctl start ssh.service` failed on line 39, the
# process died, and the self-heal block further down never ran once in ten
# nightly attempts. Every step below is guarded with `try` instead, so a
# failing step is reported but never blocks the steps after it.
#
# Ordering is load-bearing:
#   1. /run/sshd first    — un-wedges an already-broken host with no restart,
#                           and does not depend on openssh being installable.
#   2. activation model   — the distro's default: socket on Ubuntu, service on Debian.
#   3. reclaim :22        — only if the socket should own it but doesn't.
#   4. dpkg              — only after :22 is reclaimed, or the postinst refails.
#
# Nothing here ever restarts ssh.service. Under socket activation systemd owns
# the listening socket, so `RuntimeDirectory=sshd` (/run/sshd) is recreated on
# every activation and a botched restart cannot strand a listener without it.

YND_ROOT="/DATA/AppData/yundera"

YND_TEMPLATE="$YND_ROOT/template"
FAILED=0

if [ -f /.dockerenv ]; then
    echo "→ Inside Docker - dev environment detected. Skipping setup."
    exit 0
fi

# Run a step, record failure, keep going.
try() {
    if "$@"; then
        return 0
    fi
    echo "✗ step failed: $*"
    FAILED=1
    return 1
}

has_listener_22() {
    ss -ltn 'sport = :22' 2>/dev/null | grep -q LISTEN
}

# --------------------------------------------------------------------------
# 1. Privilege-separation directory
#
# `RuntimeDirectory=sshd` makes systemd delete /run/sshd when ssh.service
# stops. A stranded sshd then fatals on every connection with
# "Missing privilege separation directory: /run/sshd". Creating it here fixes
# an already-broken host instantly, with no restart and no lockout risk; the
# tmpfiles.d entry makes it survive the tmpfs being recreated at boot.
#
# This block runs before anything else — including the package install —
# so a host with wedged dpkg still gets repaired.
# --------------------------------------------------------------------------
try install -d -m 0755 -o root -g root /run/sshd

TMPFILES_CONF="/etc/tmpfiles.d/sshd.conf"
TMPFILES_CONTENT="# Managed by ensure-ssh.sh — do not edit.
d /run/sshd 0755 root root -
"
mkdir -p /etc/tmpfiles.d
# NOTE: both sides go through $(...) so the trailing newline is stripped from
# each. Comparing a raw here-string against $(cat file) never matches, because
# command substitution strips the trailing newline from one side only — that
# made the old hardening check report "changed" on every single run.
if [ ! -f "$TMPFILES_CONF" ] || \
   [ "$(cat "$TMPFILES_CONF")" != "$(printf '%s' "$TMPFILES_CONTENT")" ]; then
    printf '%s' "$TMPFILES_CONTENT" > "$TMPFILES_CONF"
    chmod 0644 "$TMPFILES_CONF"
    echo "→ Installed $TMPFILES_CONF"
fi

# --------------------------------------------------------------------------
# 2. Package
# --------------------------------------------------------------------------
try "$YND_TEMPLATE/scripts/tools/ensure-packages.sh" openssh-server

# --------------------------------------------------------------------------
# 3. Hardening drop-in
#
# Ubuntu's and Debian's default sshd_config source /etc/ssh/sshd_config.d/*.conf
# before their own settings. sshd keeps the FIRST value it reads for a keyword,
# and the drop-ins are read in lexical order, so the snippet must sort first:
# cloud-init writes 50-cloud-init.conf (`PasswordAuthentication yes` whenever
# ssh_pwauth is on, as on Contabo's images), and our former
# 99-yundera-harden.conf lost to it on every PCS — `sshd -T` reported
# `passwordauthentication yes` on holyhorse and on Debian demostaging1
# (2026-11-20). 00- wins over every distro and cloud-init drop-in.
# Idempotent: rewrite every run, only reload if the contents actually changed.
#
# MaxStartups / LoginGraceTime: a key-only sshd cannot be brute-forced, only
# flooded. holyhorse logged ~39 000 pre-auth lines a day from 145 IPs
# (2026-11-20, doc/study/pcs-edge-protection-study.md §4.5), each holding a
# MaxStartups slot for up to LoginGraceTime (default 10:30:100 and 120 s), so
# a flood can make sshd refuse the owner. 20 s is ample for a key exchange;
# 10:30:60 starts dropping new unauthenticated connections at random from 10
# and drops them all at 60. PerSourcePenalties (OpenSSH >= 9.8, Debian 13) is
# on by default there and not settable on Ubuntu 24.04's 9.6, so it is left
# to the distro default.
# --------------------------------------------------------------------------
HARDEN_FILE="/etc/ssh/sshd_config.d/00-yundera-harden.conf"
LEGACY_HARDEN_FILE="/etc/ssh/sshd_config.d/99-yundera-harden.conf"
HARDEN_CONTENT="# Managed by ensure-ssh.sh — do not edit.
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
MaxStartups 10:30:60
LoginGraceTime 20
"
mkdir -p /etc/ssh/sshd_config.d
# Same trailing-newline trap as the tmpfiles comparison above. This one was a
# live bug: HARDEN_CHANGED was ALWAYS 1, so every nightly self-check ran
# `systemctl reload ssh.service || systemctl restart ssh.service`. On an armed
# host the reload fails (service inactive under socket activation) and the
# fallback *restart* deletes /run/sshd — meaning the self-check was itself a
# nightly trigger for this incident, not just openssh upgrades.
if [ ! -f "$HARDEN_FILE" ] || \
   [ "$(cat "$HARDEN_FILE")" != "$(printf '%s' "$HARDEN_CONTENT")" ]; then
    printf '%s' "$HARDEN_CONTENT" > "$HARDEN_FILE"
    chmod 0644 "$HARDEN_FILE"
    HARDEN_CHANGED=1
else
    HARDEN_CHANGED=0
fi
# The 99- copy is inert once 00- exists (same settings, read last), but two
# managed files with one meaning is how they drift apart. Drop it.
if [ -f "$LEGACY_HARDEN_FILE" ]; then
    rm -f "$LEGACY_HARDEN_FILE"
    HARDEN_CHANGED=1
fi

# --------------------------------------------------------------------------
# 4. Activation model — exactly one
#
# Ubuntu 24.04 ships SSH socket-activated, and ssh.socket declares
# `RequiredBy=ssh.service`, so enabling the socket installs
# /etc/systemd/system/ssh.service.requires/ssh.socket. Enabling BOTH units
# (what this script used to do) means ssh.service hard-requires a socket that
# cannot bind :22 while a stray sshd holds it — every start fails, for good.
#
# Prefer socket-only: systemd owns :22, so sshd restarts never drop the
# listener and /run/sshd is recreated on each activation. Fall back to the
# traditional service on distros with no ssh.socket.
#
# `disable` is deliberately used WITHOUT `--now`: it only removes the
# multi-user.target symlink. The running listener is left completely alone, so
# this converges the host at its next boot with zero risk of cutting SSH now.
# --------------------------------------------------------------------------
# Which model is decided per distro (library/platform.sh): Ubuntu ships
# socket-activated, Debian ships an ssh.socket unit but runs ssh.service, so a
# Debian host stays on the service. A host whose socket is already enabled stays
# on it whatever the distro — the choice never flips back and forth.
#
# Tolerate a missing platform.sh (a tree older than v1.17.0, or this file run
# by hand): SSH is the one thing this script must never get wrong for want of
# a library, so fall back to the same rule inline.
if [ -f "$YND_TEMPLATE/scripts/library/platform.sh" ]; then
    source "$YND_TEMPLATE/scripts/library/platform.sh"
else
    platform_ssh_socket_is_default() { [ "$( . /etc/os-release 2>/dev/null; echo "${ID:-}" )" = "ubuntu" ]; }
fi
if ! systemctl cat ssh.socket >/dev/null 2>&1; then
    SOCKET_MODE=0
elif platform_ssh_socket_is_default || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    SOCKET_MODE=1
else
    SOCKET_MODE=0
fi

if [ "$SOCKET_MODE" = "1" ]; then
    echo "→ SSH activation model: socket (ssh.socket)"
    try systemctl enable ssh.socket
    try systemctl disable ssh.service
else
    echo "→ SSH activation model: service (ssh.service is this distro's default)"
    try systemctl enable ssh.service
    if ! has_listener_22; then
        try systemctl start ssh.service
    fi
fi

# Reload only — never restart. Under socket activation each connection spawns a
# fresh sshd that reads the config anyway, so a reload is only needed for a
# long-lived activated instance.
if [ "$HARDEN_CHANGED" = "1" ]; then
    echo "→ Applied SSH hardening (password auth off, MaxStartups 10:30:60, LoginGraceTime 20)"
    if systemctl is-active --quiet ssh.service; then
        try systemctl reload ssh.service
    fi
fi

# --------------------------------------------------------------------------
# 5. Reclaim :22 if the socket should own it but doesn't
#
# Guard: socket mode AND ssh.socket not active. On a healthy socket-activated
# host ssh.socket is active, so this block is unreachable — important, because
# it kills a listener and runs unattended on every PCS nightly.
#
# Gentle path first (just start the socket). Only if :22 is genuinely held by
# a stray sshd do we kill it. The holder is identified from `ss` and confirmed
# via /proc/<pid>/comm — never a `pkill -f` pattern match, because a healthy
# socket-activated sshd carries the exact same process title
# ("sshd: /usr/sbin/sshd -D [listener]") and would be caught by it.
#
# Killing the listener does not drop live sessions (ssh.service sets
# KillMode=process, and session processes are separate children), and SSH is
# not on the self-heal path anyway — cron runs on the host. Worst case is
# refused connections until the next tick, which converges from this state.
# --------------------------------------------------------------------------
if [ "$SOCKET_MODE" = "1" ] && ! systemctl is-active --quiet ssh.socket; then
    echo "→ ssh.socket is not active; reclaiming port 22"

    systemctl start ssh.socket 2>/dev/null

    if ! systemctl is-active --quiet ssh.socket; then
        # Still not up: something else holds :22. Find it, verify it is sshd.
        HOLDERS=$(ss -ltnp 'sport = :22' 2>/dev/null \
                  | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
        for pid in $HOLDERS; do
            [ "$pid" = "1" ] && continue
            comm=$(cat "/proc/$pid/comm" 2>/dev/null)
            if [ "$comm" != "sshd" ]; then
                echo "  ! pid $pid holds :22 but is '$comm', not sshd — leaving it alone"
                continue
            fi
            echo "  → killing stray sshd listener pid $pid"
            kill "$pid" 2>/dev/null
        done

        # Give the port a moment to free, then bring the socket up.
        for _ in 1 2 3 4 5; do
            has_listener_22 || break
            sleep 1
        done
        try systemctl restart ssh.socket
    fi

    # Break glass: never leave the host without a listener. A bare sshd is
    # unmanaged, but the guard above (socket not active + :22 held by sshd)
    # reclaims it on the next tick, so this still converges.
    if ! has_listener_22; then
        echo "  ! no listener on :22 after reclaim — starting a bare sshd as fallback"
        try /usr/sbin/sshd
    fi
fi

# --------------------------------------------------------------------------
# 6. Clear a half-configured openssh
#
# A failed postinst leaves the package `iF` (half-configured), which blocks
# every later apt install on the host and hides an unpatched running binary
# behind a patched version string. Must run AFTER :22 is reclaimed — the
# postinst restarts SSH and would fail again otherwise.
# --------------------------------------------------------------------------
DPKG_SAFE=1
if [ "$SOCKET_MODE" = "1" ] && ! systemctl is-active --quiet ssh.socket; then
    DPKG_SAFE=0
fi

if [ "$DPKG_SAFE" = "0" ]; then
    echo "→ skipping dpkg repair: port 22 not yet reclaimed, postinst would refail"
elif dpkg-query -W -f='${Status}\n' openssh-server 2>/dev/null \
     | grep -q 'half-configured\|half-installed'; then
    echo "→ openssh-server is half-configured; completing configuration"
    [ -x "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh" ] && \
        "$YND_TEMPLATE/scripts/tools/wait-for-apt-lock.sh"
    DEBIAN_FRONTEND=noninteractive try dpkg --configure openssh-server
fi

# --------------------------------------------------------------------------
# 7. Health check
#
# A listener on :22 is the authoritative signal. `systemctl is-active
# ssh.service` is NOT: under socket activation the service is legitimately
# inactive on an idle host, and testing it would fire remediation on healthy
# machines.
#
# The old remedy here was `dpkg-reconfigure openssh-server` + `systemctl
# restart ssh.service`. Both are gone: reconfigure is a config-regenerating
# hammer that never addressed this failure class, and on a box where SSH is
# the only human access it is more dangerous than the fault it targets.
# --------------------------------------------------------------------------
SSH_OK=1

if ! has_listener_22; then
    echo "✗ nothing is listening on port 22"
    SSH_OK=0
fi

if ! sshd -t 2>/dev/null; then
    echo "✗ sshd configuration is invalid:"
    sshd -t 2>&1 | sed 's/^/    /'
    SSH_OK=0
fi

# The effective value, not the file: a drop-in that sorts before ours can
# override it silently (see §3). `sshd -T` prints what sshd would really use.
EFFECTIVE_PWAUTH="$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2}')"
if [ "$EFFECTIVE_PWAUTH" != "no" ]; then
    echo "✗ effective PasswordAuthentication is '${EFFECTIVE_PWAUTH:-unknown}', not 'no' — another sshd_config.d drop-in overrides $HARDEN_FILE"
    SSH_OK=0
fi

if [ "$SOCKET_MODE" = "1" ]; then
    if systemctl is-failed --quiet ssh.socket; then
        echo "✗ ssh.socket is in failed state"
        SSH_OK=0
    fi
    if systemctl is-enabled --quiet ssh.service 2>/dev/null; then
        echo "✗ ssh.service is still enabled alongside ssh.socket (they fight over :22)"
        SSH_OK=0
    fi
else
    if ! systemctl is-active --quiet ssh.service; then
        echo "✗ ssh.service is not active"
        SSH_OK=0
    fi
fi

if [ "$SSH_OK" = "1" ]; then
    echo "✓ SSH is healthy (listener on :22, config valid, single activation model)"
else
    echo "✗ SSH is still unhealthy after convergence — see above"
    FAILED=1
fi

exit "$FAILED"
