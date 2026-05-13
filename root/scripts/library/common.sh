#!/bin/bash
# Common utility functions for scripts

SCRIPT_DIR="/DATA/AppData/casaos/apps/yundera/scripts"

# Source the common logging utilities
source ${SCRIPT_DIR}/library/log.sh

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    exit 0
}

# Returns 0 (true) when the host is a Yundera Proxmox-style VM (LVM on
# /dev/sda, qemu-guest-agent, CPU/RAM hotplug), 1 otherwise. Used by the
# four hypervisor-aware ensure-*.sh scripts to gate their setup work.
#
# Detection order:
#   1. /etc/yundera/provider override file — provisioner-set, lives outside
#      /DATA so a migration rsync can't clobber it. Authoritative when present.
#   2. `data_vg` LVM volume group exists — host has already been carved by
#      ensure-data-partition.sh, so it's definitely Proxmox-managed.
#   3. /dev/sda has ≥1.1GB of unallocated space — fresh Proxmox golden
#      template, ready to be carved on first self-check pass.
#   4. Otherwise — commodity VPS (Contabo, Hetzner, etc.) where the disk
#      ships fully partitioned with no room for LVM.
#
# Replaces the old `${YND_PROVIDER:-proxmox}` env var, which read its value
# from /DATA/AppData/casaos/apps/yundera/.pcs.env — a path inside the
# rsynced data tree, so a cross-provider migration target would inherit the
# source's provider identity and run the wrong setup path. The disk-layout
# heuristic above is intrinsic to the *target* host, not copied data.
is_proxmox_host() {
    if [ -r /etc/yundera/provider ]; then
        case "$(cat /etc/yundera/provider 2>/dev/null)" in
            proxmox) return 0 ;;
            *)       return 1 ;;
        esac
    fi
    if vgdisplay data_vg >/dev/null 2>&1; then
        return 0
    fi
    if parted -s /dev/sda unit MB print free 2>/dev/null \
        | awk '/Free Space/ { gsub("MB",""); if ($3+0 > 1100) f=1 } END { exit !f }'; then
        return 0
    fi
    return 1
}