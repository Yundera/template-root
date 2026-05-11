# System Setup Scripts

This folder contains idempotent setup scripts that ensure various system components are properly configured. Each script can be run multiple times safely.

## Script Responsibilities

Listed in execution order from `scripts-config.txt`. Five scripts marked **(proxmox-only)** early-exit when `YND_PROVIDER` is not `proxmox`.

| Script | Purpose |
|--------|---------|
| `ensure-pcs-user.sh` | Creates 'pcs' user with sudo privileges and required directory structure |
| `ensure-script-executable.sh` | Makes all scripts executable and sets proper ownership to the pcs user |
| `ensure-admin-user.sh` | Configures the admin user account inside the PCS |
| `ensure-template-sync.sh` | Downloads `UPDATE_URL`, runs migrations from the new tree, then rsyncs over `/DATA/AppData/casaos/apps/yundera/` |
| `ensure-yundera-user-data.sh` | Materialises user-specific state from `.ynd.user.env` |
| `ensure-ubuntu-up-to-date.sh` | Updates package lists and displays available system upgrades |
| `ensure-common-tools-installed.sh` | Installs essential system tools (htop, vim, etc.) |
| `ensure-ssh.sh` | Installs and configures OpenSSH server |
| `ensure-vm-scalable.sh` | **(proxmox-only)** Configures VM for CPU and RAM hotplug capabilities |
| `ensure-qemu-agent.sh` | **(proxmox-only)** Installs and starts QEMU guest agent for VM integration |
| `ensure-public-ip.sh` | Detects and stores public IP addresses (IPv4/IPv6) in environment |
| `ensure-data-partition.sh` | **(proxmox-only)** Creates and mounts resizable LVM partition with bind mounts for `/DATA` and `/var/lib/docker` |
| `ensure-data-partition-size.sh` | **(proxmox-only)** Automatically extends the DATA partition when additional disk space becomes available |
| `ensure-swap.sh` | Creates and configures swap file with optimised swappiness settings |
| `ensure-self-check-at-reboot.sh` | Installs the `@reboot` cron entry that runs `self-check-reboot.sh` |
| `ensure-nightly-self-check.sh` | Installs the nightly cron entry that runs `self-check.sh` directly |
| `ensure-logrotate.sh` | Configures daily log rotation for `yundera.log` (7-day retention) |
| `ensure-docker-installed.sh` | Installs and configures Docker CE with proper user permissions |
| `ensure-env-vars-valid.sh` | Validates required env vars across `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` |
| `ensure-yundera-support-key.sh` | Authorises the Yundera support SSH key (operator-controllable) |
| `ensure-auth-secrets.sh` | Generates Authelia secrets (session/storage/reset/oidc-hmac, RSA-4096 JWKS) and re-renders `auth/configuration.yml` from `auth/configuration.yml.tmpl` |
| `ensure-casaos-apps-up-to-date.sh` | Re-renders `docker-compose.yml` from the template and current env files |
| `ensure-user-compose-pulled.sh` | Pulls latest images for the user's Docker Compose services |
| `ensure-user-compose-stack-up.sh` | Starts the user's Docker Compose stack in detached mode |

The list is authoritative — order is controlled by `scripts-config.txt`, not filename alphabetisation. When adding a new script, also add a line to `scripts-config.txt` in the right position.

## Integration Points

When adding a new self-check script:

1. Place the script in `root/scripts/self-check/`.
2. Add a line to `root/scripts/self-check/scripts-config.txt` in the correct execution position.
3. If it touches hypervisor-specific surface, gate it on `${YND_PROVIDER:-proxmox}` like the proxmox-only scripts above.
4. Source `library/common.sh` to get `log`, `log_error`, and `execute_script_with_logging`.

No edits are needed in the orchestrator or `settings-center-app` — the admin app calls `self-check.sh` and inherits whatever's in the config file.

## Notes

- All scripts are designed to be idempotent (safe to run multiple times)
- Scripts detect Docker environments and skip operations where appropriate
- Most scripts require root privileges to execute system-level changes

## Logs

### Log Location
All yundera system logs are written to:
```
/DATA/AppData/casaos/apps/yundera/log/yundera.log
```

### Viewing Logs
```bash
# View current log
cat /DATA/AppData/casaos/apps/yundera/log/yundera.log

# Follow log in real-time
tail -f /DATA/AppData/casaos/apps/yundera/log/yundera.log

# View recent entries
tail -100 /DATA/AppData/casaos/apps/yundera/log/yundera.log
```

### Rotated Logs
Logs are rotated daily with 7-day retention. Rotated logs are located at:
```
/DATA/AppData/casaos/apps/yundera/log/yundera.log-YYYY-MM-DD      # Yesterday's log
/DATA/AppData/casaos/apps/yundera/log/yundera.log-YYYY-MM-DD.gz   # Older compressed logs
```

To view all available logs:
```bash
ls -la /DATA/AppData/casaos/apps/yundera/log/
```

To view a compressed rotated log:
```bash
zcat /DATA/AppData/casaos/apps/yundera/log/yundera.log-2026-02-10.gz
```