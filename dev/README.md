# Template-Root Development Environment

This directory contains a Docker-based test environment for developing and testing template-root scripts.

## Quick Start

```bash
# Build and start the test container
docker compose up -d --build

# Exec into the container
docker exec -it template-root-test bash

# Run Caddy labels migration
bash /DATA/AppData/casaos/apps/yundera/scripts/migrations/2026-02-11-10-ensure-caddy-labels.always.sh

# Check results (multi-service app - only main service gets labels)
yq '.services' /DATA/AppData/casaos/apps/openclaw/docker-compose.yml

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
