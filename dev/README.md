# Template-Root Development Environment

This directory contains a Docker-based test environment for developing and testing template-root scripts.

## Quick Start

```bash
# Build and start the test container
docker compose up -d --build

# Exec into the container
docker exec -it template-root-test bash

# Run an individual self-check or migration
bash /DATA/AppData/casaos/apps/yundera/scripts/self-check/ensure-auth-secrets.sh
bash /DATA/AppData/casaos/apps/yundera/scripts/migrations/YYYY-MM-DD-HH-name.sh

# Force the container to skip download/rsync and run migrations against the in-place tree
/DATA/AppData/casaos/apps/yundera/scripts/tools/env-file-manager.sh \
    set UPDATE_URL local /DATA/AppData/casaos/apps/yundera/.pcs.env

# Run the full self-check loop (two-pass over scripts-config.txt)
bash /DATA/AppData/casaos/apps/yundera/scripts/self-check.sh

# Inspect a generated app compose file
yq '.services' /DATA/AppData/casaos/apps/<app-name>/docker-compose.yml

# Stop the container
docker compose down
```

## Structure

- `Dockerfile` - Ubuntu base with common tools (wget, unzip, rsync, yq)
- `docker-compose.yml` - Test stack configuration
- `test-pcs.env` - Test PCS environment variables
- `test-pcs.secret.env` - Test secrets
- `test-ynd.user.env` - Test user environment

## Test Apps

Production apps are copied from `/d/workspace/tmp-claude/apps/` at container startup:
- **Single-service apps**: firefox, funkwhale, claude, yacy, etc.
- **Multi-service apps**: openclaw (2 services), segment (2 services)
- **Excluded**: yundera (core stack - uses template-root itself)

The apps are copied fresh each time the container starts, so you can safely test migrations without modifying originals.

## Environment

The container simulates a PCS environment:
- `/DATA/AppData/casaos/apps/` - CasaOS apps directory (copied from production)
- `/DATA/AppData/casaos/apps/yundera/` - Template-root scripts location
