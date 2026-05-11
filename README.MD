# Template System

This folder contains the template system for Yundera Personal Cloud Server (PCS) provisioning, including first-install bootstrap, periodic self-checks, and continuous template/app updates. It supports multiple hypervisor providers (`proxmox`, `contabo`) via the `YND_PROVIDER` tag in `.pcs.env`.

## Folder Structure

```
root/                        # Files installed to /DATA/AppData/casaos/apps/yundera
├── .pcs.env                 # PCS configuration environment variables
├── .pcs.secret.env          # Secret environment variables (JWT, passwords, etc.)
├── .ynd.user.env            # User-specific environment variables
├── docker-compose.yml       # Core services stack (admin, casaos, mesh-router-*, smtp, authelia)
├── Caddyfile                # Caddy gateway global config (per-app routes come from container labels)
├── auth/configuration.yml.tmpl  # Authelia config template (rendered each self-check)
└── scripts/
    ├── pcs-init.sh          # First-install bootstrap (fetched from jsDelivr by the orchestrator)
    ├── self-check.sh        # Core iterator over scripts-config.txt (used by nightly cron + admin app)
    ├── self-check-reboot.sh # @reboot wrapper: lock + self-check + compose restart
    ├── self-check/          # Idempotent ensure-*.sh scripts + scripts-config.txt (order matters)
    ├── migrations/          # Version-bump update scripts (run before each template rsync)
    ├── tools/               # CLI / one-shot utilities (os-init, run-migrations, env-file-manager, ...)
    └── library/             # Sourced helpers (common.sh, log.sh)
```

## Script Categories

### pcs-init.sh
Orchestrator-side bootstrap, fetched from jsDelivr at create time and run once per fresh Ubuntu host. Assumes `.pcs.env` and `.pcs.secret.env` are already staged. Fetches the template tree via `tools/template-download.sh`, then hands off to `tools/os-init.sh`. See `pcs-orchestrator/src/library/provisioning/runHostBootstrap.ts`.

### self-check.sh
Core iterator that runs every script listed in `self-check/scripts-config.txt`. Two-pass over the config (handles mid-run replacement by `ensure-template-sync.sh`). Used by the nightly cron, the admin container (`settings-center-app`), and `self-check-reboot.sh`.

### self-check-reboot.sh
Thin @reboot wrapper. Holds `flock` on `/var/run/yundera-self-check.lock` across both `self-check.sh` and the user compose stack restart. Honours `PCS_PROVISIONING=1` (set by `os-init.sh`) for fail-fast first-run behaviour; otherwise masks errors with `|| true`.

### self-check/
Idempotent ensure-scripts. Order is controlled by `scripts-config.txt` — there is no auto-discovery. See `self-check/README.MD`.

### migrations/
Filename-ordered scripts run from the *newly-downloaded* template tree before rsync (so they can preflight state for an unreleased version). A failure aborts template sync. See `migrations/README.md`.

### tools/
Utility scripts invoked by other parts of the system or operators: `os-init.sh`, `run-migrations.sh`, `env-file-manager.sh`, `register-oidc-client.sh`, `template-download.sh`, etc.

## Configuration Files

- **`.pcs.env`**: PCS configuration variables (system settings, `UPDATE_URL`, `YND_PROVIDER`, default service host/port)
- **`.pcs.secret.env`**: Secret environment variables (JWT tokens, passwords, signatures)
- **`.ynd.user.env`**: User-specific data (UID, domain, email, username, public IP)

These files feed `ensure-casaos-apps-up-to-date.sh`, which re-renders `/DATA/AppData/casaos/apps/yundera/docker-compose.yml` on every self-check tick. Always mutate them via `tools/env-file-manager.sh` — never raw `sed`/`grep`.

### Environment Variables

The environment files support the following configuration options:

| Variable | Description | File | Default |
|----------|-------------|------|---------|
| `DOMAIN` | User's domain name | `.ynd.user.env` | Required |
| `UID` | User ID | `.ynd.user.env` | Required |
| `EMAIL` | User email address | `.ynd.user.env` | Required |
| `USERNAME` | System username | `.ynd.user.env` | Required |
| `DEFAULT_USER` | Default username | `.pcs.env` | Required |
| `PUBLIC_IPV4` | Public IPv4 address (if available) | `.pcs.env` | Optional |
| `PUBLIC_IPV6` | Public IPv6 address (if available) | `.pcs.env` | Optional |
| `USER_JWT` | Yundera JWT token | `.pcs.secret.env` | Required |
| `DEFAULT_PWD` | Default password | `.pcs.secret.env` | Required |
| `PROVIDER_STR` | Provider configuration string | `.pcs.secret.env` | Required |
| `YND_PROVIDER` | Hypervisor tag — gates Proxmox-only ensure-scripts | `.pcs.env` | `proxmox` (also `contabo`) |
| `UPDATE_URL` | Template zip URL for updates (or literal `local` for dev) | `.pcs.env` | `https://github.com/Yundera/template-root/archive/refs/heads/stable.zip` |
| `DEFAULT_SERVICE_HOST` | Catch-all target for custom domains (see Caddyfile docs) | `.pcs.env` | `casaos` |
| `DEFAULT_SERVICE_PORT` | Catch-all target port | `.pcs.env` | `8080` |

#### Template Repository Configuration

The `UPDATE_URL` variable must be a direct zip file URL for downloading template updates:

- **Official template (stable)**: `https://github.com/Yundera/template-root/archive/refs/heads/stable.zip` (default)
- **Tracking main**: `https://github.com/Yundera/template-root/archive/refs/heads/main.zip`
- **Custom fork**: `https://github.com/your-username/template-root/archive/refs/heads/main.zip`
- **Any zip URL**: Must end with `.zip` and contain a valid template structure
- **Dev escape hatch**: `local` — skips download/rsync and runs migrations against the in-place tree (used by the `dev/` test container)

**Requirements:**
- URL must end with `.zip` (the `local` literal is the only exception)
- Zip file must contain a `root/` directory with the template structure
- If `UPDATE_URL` is unset, the default `stable.zip` URL is used

## Usage Context

This folder is designed to be:

1. Fetched from jsDelivr by the orchestrator on first install (via `pcs-init.sh`).
2. Deployed to `/DATA/AppData/casaos/apps/yundera/` on each PCS host.
3. Kept current by ongoing self-check + template-sync runs (no operator action required).

## Update Process

The template tree is intentionally mutable after first install — every self-check tick can pull a newer version of itself and re-render the user stack.

### Update Triggers

1. **@reboot cron** — `self-check-reboot.sh` (installed by `ensure-self-check-at-reboot.sh`)
2. **Nightly cron** — `self-check.sh` (installed by `ensure-nightly-self-check.sh`)
3. **Admin container** — `settings-center-app` invokes `self-check-reboot.sh` on its own schedule

### Update Workflow (tail of `scripts-config.txt`)

All triggers run the same four-step sequence at the end of `scripts-config.txt`:

1. **`self-check/ensure-template-sync.sh`** (RUNS FIRST)
   Downloads `UPDATE_URL`, runs **migrations from the new tree** first, then rsyncs over `/DATA/AppData/casaos/apps/yundera/` (honouring `root/.ignore`). A failed migration aborts the sync and restores the previous tree from backup.

2. **`self-check/ensure-casaos-apps-up-to-date.sh`**
   Re-renders the user's `docker-compose.yml` from the (possibly updated) template and current env files.

3. **`self-check/ensure-user-compose-pulled.sh`**
   `docker compose pull` for the user stack — fetches image versions pinned by the new template.

4. **`self-check/ensure-user-compose-stack-up.sh`**
   `docker compose up -d` to apply.

Earlier entries in `scripts-config.txt` are host-level prerequisites (user, ssh, partitions, swap, docker install, public IP detection, auth secrets, cron installation, etc.).

### Post-Update Verification

The admin container (`settings-center-app`) runs additional health checks against the running stack after each periodic self-check tick.

## System Logging Philosophy

All scripts follow a **"quiet success, verbose failure"** principle: show only essential information during normal operation, but provide comprehensive debugging details when things go wrong.

### Core Principles

**1. Users care about outcomes, not process**
- Show final status: `✓ migration.sh completed` or `✓ migration.sh (skipped - already applied)`
- Hide process messages: Don't log "Found file", "Running", "Starting", "Processing N files"
- Exception: Show actual work output for one-shot operations that change the system

**2. Failed operations need full context**  
- Capture all output when commands fail, then display it for debugging
- Include exit codes, file information, and retry suggestions
- Example: `apt-get` runs silently but shows full output on failure

**3. Progressive disclosure of information**
- Start with minimal output during success
- Add layers of detail only when failures occur
- Use output redirection (`>/dev/null 2>&1`) for background operations, capture for error display

### Implementation Pattern

```bash
# Good: Quiet success, verbose failure
if ! command >/dev/null 2>&1; then
    echo "Error: Command failed, running with verbose output:"
    command  # Show full output for debugging
    exit 1
fi

# Bad: Always verbose
echo "Running command..."
command
echo "Command completed"
```

### Real Examples

**Migration execution**: 
- Success: `✓ migrate-env.sh (skipped - already applied)`
- Failure: Shows full migration output with error details

**Package installation**:
- Success: `Installing required tools...` (single line)  
- Failure: Full `apt-get` output with package conflicts

**Template sync**:
- Success: `Template sync completed` 
- Failure: Full `rsync` output showing which files failed

This philosophy prioritizes user experience: clean logs that focus on what matters, with comprehensive debugging when needed.
