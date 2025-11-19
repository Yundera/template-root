# System Setup Scripts

This folder contains idempotent setup scripts that ensure various system components are properly configured. Each script can be run multiple times safely.

## Script Responsibilities

| Script | Purpose |
|--------|---------|
| `ensure-common-tools-installed.sh` | Installs essential system tools (htop, vim) |
| `ensure-data-partition-size.sh` | Automatically extends DATA partition when additional disk space becomes available |
| `ensure-data-partition.sh` | Creates and mounts 1GB resizable LVM partition with bind mounts for /DATA and /var/lib/docker |
| `ensure-docker-installed.sh` | Installs and configures Docker CE with proper user permissions |
| `ensure-pcs-user.sh` | Creates 'pcs' user with sudo privileges and required directory structure |
| `ensure-qemu-agent.sh` | Installs and starts QEMU guest agent for VM integration |
| `ensure-script-executable.sh` | Makes all scripts executable and sets proper ownership to pcs user |
| `ensure-self-check-at-reboot.sh` | Configures cron job to run self-check script at system boot |
| `ensure-ssh.sh` | Installs and configures OpenSSH server |
| `ensure-public-ip.sh` | Detects and stores public IP addresses (IPv4/IPv6) in environment; currently supports IPv6 via SLAAC on ens19 |
| `ensure-swap.sh` | Creates and configures 4GB swap file with optimized swappiness settings |
| `ensure-ubuntu-up-to-date.sh` | Updates package lists and displays available system upgrades |
| `ensure-user-compose-pulled.sh` | Pulls latest images for user's Docker Compose services |
| `ensure-user-compose-stack-up.sh` | Starts user's Docker Compose stack in detached mode |
| `ensure-user-docker-compose-updated.sh` | Generates docker-compose.yml from template using environment variables |
| `ensure-vm-scalable.sh` | Configures VM for CPU and RAM hotplug capabilities |

## Integration Points

When adding a new self-check script, ensure it's integrated into:

1. `packages/settings-center-app/settings-dashboard/src/backend/server/SelfCheck.ts`
2. `packages/settings-center-app/template-setup/root/scripts/self-check-reboot.sh`
3. `packages/settings-center-app/template-setup/root/scripts/template-init.sh`

## Notes

- All scripts are designed to be idempotent (safe to run multiple times)
- Scripts detect Docker environments and skip operations where appropriate
- Most scripts require root privileges to execute system-level changes