# Template Migration System

This directory contains migration scripts that are executed during template synchronization to handle changes between template versions.

## Migration Script Naming Convention

Migration scripts must follow the naming format: `YYYY-MM-DD-HH-name.sh`

Examples:
- `2024-01-15-10-update-docker-compose.sh`
- `2024-02-20-14-migrate-config-format.sh`
- `2024-03-05-09-fix-permissions.sh`

### Always-Run Migrations

For migrations that need to run on **every** template sync (not just once), use the `.always.sh` suffix:

Format: `YYYY-MM-DD-HH-name.always.sh`

Examples:
- `2024-03-10-10-ensure-app-env-files.always.sh`
- `2024-04-15-12-validate-config.always.sh`

Always-run migrations:
- Execute on every template sync
- Do not create or check marker files
- Must handle their own idempotency (check state before making changes)
- Useful for ensuring state consistency after new apps are installed

## Execution Order

Migration scripts are executed in **alphabetical order** based on their filenames. This ensures chronological execution when using the proper naming format.

## Migration Script Requirements

### 1. Idempotent Design
Migration scripts must be **idempotent** - they can be run multiple times safely without causing issues or duplicate changes.

### 2. Error Handling
- Scripts should exit with code `0` on success
- Scripts should exit with non-zero code on failure
- Migration failure will prevent template sync from proceeding

### 3. Output
Use simple echo statements for logging and user feedback:
```bash
echo "Starting migration: $(basename "$0")"
echo "Migration completed successfully" 
echo "Error: Migration failed: error message"
echo "Warning: Warning message"
```

### 4. Script Template
```bash
#!/bin/bash
set -euo pipefail

MIGRATION_NAME="$(basename "$0")"
MARKER_FILE="/DATA/AppData/casaos/apps/yundera/migration-markers/$(basename "$0" .sh).marker"

echo "Starting migration: $MIGRATION_NAME"

# Create marker directory if it doesn't exist
mkdir -p "$(dirname "$MARKER_FILE")"

# Check if migration has already been applied (idempotent check)
if [ -f "$MARKER_FILE" ]; then
    echo "Migration $MIGRATION_NAME already applied, skipping"
    exit 0
fi

# Perform migration steps
# ... migration logic here ...

# Create marker file to indicate successful completion
echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER_FILE"
echo "Migration: $MIGRATION_NAME" >> "$MARKER_FILE"

echo "Migration $MIGRATION_NAME completed successfully"
```

## Migration Execution

Migrations are automatically executed by the template sync system:
1. Before copying new template files
2. In alphabetical order (chronological when properly named)
3. From a temporary directory containing the new template
4. Migration failure prevents template sync

## Best Practices

1. **Test migrations thoroughly** in development environment
2. **Keep migrations small and focused** on specific changes
3. **Document migration purpose** in script comments
4. **Use proper error handling** and logging
5. **Implement robust idempotent checks** to prevent duplicate execution
6. **Backup critical data** before making changes when possible

## Migration Types

### One-Shot Migrations (default)
Standard migrations that run once and are tracked with marker files:
- Configuration file format changes
- Directory structure modifications
- Permission updates
- Service configuration updates
- Database schema changes (if applicable)
- File cleanup and reorganization

### Always-Run Migrations (.always.sh)
Migrations that run on every template sync:
- Ensuring config files exist for newly installed apps
- Validating and repairing system state
- Generating derived configuration from environment
- Cleanup tasks that should run periodically