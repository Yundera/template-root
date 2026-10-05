# System Setup Scripts

This folder contains idempotent setup scripts that ensure various system components are properly configured. Each script can be run multiple times safely.

## Script Responsibilities

Listed in execution order from `scripts-config.txt`.

| Script | Purpose |
|--------|---------|
| `ensure-pcs-user.sh` | Creates 'pcs' user with sudo privileges and required directory structure |
| `ensure-script-executable.sh` | Makes all scripts executable and sets proper ownership to the pcs user |
| `ensure-admin-user.sh` | Configures the admin user account inside the PCS |
| `ensure-support-key.sh` | Authorises the operator's support SSH key (operator-controllable, `ENSURE_SUPPORT_KEY` in `.pcs.env`) |
| `ensure-template-sync.sh` | Downloads `UPDATE_URL`, runs migrations from the new tree, then rsyncs `template/` over `/DATA/AppData/yundera/template/` |
| `ensure-outbound-ip-family.sh` | Prefers IPv4 for dual-stack outbound connections (gai.conf) — the GHCR IPv6 path is unreliable |
| `ensure-yundera-user-data.sh` | Fetches `/user/info` from `OPERATOR_API`: `UID`/`DOMAIN`/`EMAIL` into `.ynd.user.env`, `PROVIDER_STR`/`USER_JWT` into `.pcs.secret.env` |
| `ensure-ubuntu-up-to-date.sh` | Updates package lists and displays available system upgrades |
| `ensure-common-tools-installed.sh` | Installs essential system tools (htop, vim, etc.) |
| `ensure-ssh.sh` | Installs and configures OpenSSH server |
| `ensure-swap.sh` | Creates and configures swap file with optimised swappiness settings |
| `ensure-self-check-at-reboot.sh` | Installs the `@reboot` cron entry that runs `self-check-reboot.sh` |
| `ensure-nightly-self-check.sh` | Installs the nightly cron entry that runs `self-check.sh` directly (`SELF_CHECK_CRON` in `.pcs.env`) |
| `ensure-logrotate.sh` | Configures daily log rotation for `yundera.log` (7-day retention) |
| `ensure-docker-installed.sh` | Installs and configures Docker CE with proper user permissions |
| `ensure-backup-credentials.sh` | Fetches/rotates the S3 backup credential into the kopia stack's own `/DATA/AppData/kopia/.stack.env` (`BACKUP_*`; moved out of `.pcs.secret.env` on first run) |
| `ensure-backup-config.sh` | Connects the kopia repository from those `BACKUP_*` values |
| `ensure-ipv6-interface.sh` | Configures the provider's IPv6 interface so the mesh template finds the address |
| `ensure-mesh-installed.sh` | Installs the stock mesh template once, and writes this template's inputs into its `.env` (`library/mesh.sh`) |
| `ensure-env-vars-valid.sh` | Validates required env vars across `.pcs.env`, `.pcs.secret.env`, `.ynd.user.env` and writes the yundera stack's `.env`: the keys `docker-compose.yml` interpolates, from those three and the stack's own `.stack.env` (`library/env.sh`) |
| `ensure-connector-yundera.sh` | Writes the "Yundera Login" Dex connector drop-in (`YUNDERA_LOGIN_ENABLED` in `.pcs.env`) |
| `ensure-user-compose-pulled.sh` | Pulls latest images for the `yundera` stack |
| `ensure-user-compose-stack-up.sh` | Mints `ADMIN_ASSERTION_SECRET` (shared by the admin gate and the admin app) and the gate's session dir, then starts the `yundera` stack (admin gate + admin app) in detached mode |
| `ensure-kopia-stack.sh` | Deploys the `kopia` stack to `/DATA/AppData/kopia` through `tools/deploy-stack.sh` |
| `ensure-maison-onboarding.sh` | Writes or removes Maison's onboarding gate (`/DATA/AppData/maison/onboarding.json`) |

The list is authoritative — order is controlled by `scripts-config.txt`, not filename alphabetisation. When adding a new script, also add a line to `scripts-config.txt` in the right position.

## Integration Points

When adding a new self-check script:

1. Place the script in `root/scripts/self-check/`.
2. Add a line to `root/scripts/self-check/scripts-config.txt` in the correct execution position.
3. If it touches hypervisor-specific surface, source `library/common.sh` and gate with `if ! is_proxmox_host; then ... exit 0; fi` like the proxmox-only scripts above.
4. Source `library/common.sh` to get `log`, `log_error`, `execute_script_with_logging`, and `is_proxmox_host`.

No edits are needed in the orchestrator or `settings-center-app` — the admin app calls `self-check.sh` and inherits whatever's in the config file.

## Notes

- All scripts are designed to be idempotent (safe to run multiple times)
- Scripts detect Docker environments and skip operations where appropriate
- Most scripts require root privileges to execute system-level changes

## Logs

### Log Location
All yundera system logs are written to:
```
/DATA/AppData/yundera/log/yundera.log
```

### Viewing Logs
```bash
# View current log
cat /DATA/AppData/yundera/log/yundera.log

# Follow log in real-time
tail -f /DATA/AppData/yundera/log/yundera.log

# View recent entries
tail -100 /DATA/AppData/yundera/log/yundera.log
```

### Rotated Logs
Logs are rotated daily with 7-day retention. Rotated logs are located at:
```
/DATA/AppData/yundera/log/yundera.log-YYYY-MM-DD      # Yesterday's log
/DATA/AppData/yundera/log/yundera.log-YYYY-MM-DD.gz   # Older compressed logs
```

To view all available logs:
```bash
ls -la /DATA/AppData/yundera/log/
```

To view a compressed rotated log:
```bash
zcat /DATA/AppData/yundera/log/yundera.log-2026-02-10.gz
```