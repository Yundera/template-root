#!/bin/bash
set -euo pipefail

# Template Migration Execution Script
# Runs all migration scripts in alphabetical order from a specified directory
# Usage: run-migrations.sh <migrations_directory>

MIGRATIONS_DIR="${1:-}"

# Where the one-shot markers live.
#
# An empty marker directory does not mean "nothing has been applied" — it means
# "this is a tree that has never run migrations", and read literally it replays
# every migration in the tree at once. Until 2026-09-15 this block seeded the
# directory from /DATA/AppData/casaos/apps/yundera/migration-markers to carry a
# box's history across the root move; it was retired with
# 2026-09-08-12-move-root-to-maison.sh, once every box in the fleet carried its
# own $MARKER_DIR. A box restored from a pre-move backup is the only way back to
# that state, and it needs the marker directory restored with it.
MARKER_DIR="/DATA/AppData/yundera/migration-markers"

if [ -z "$MIGRATIONS_DIR" ]; then
    echo "Error: Usage: $0 <migrations_directory>"
    exit 1
fi

if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo "Error: Migrations directory does not exist: $MIGRATIONS_DIR"
    exit 1
fi

# Count total migration files
migration_count=$(find "$MIGRATIONS_DIR" -name "*.sh" -type f | wc -l)

if [ "$migration_count" -eq 0 ]; then
    echo "No migrations to run"
    exit 0
fi

# Track migration execution
executed_count=0
failed_count=0
skipped_count=0

# Execute migrations in alphabetical order
while IFS= read -r -d '' migration_file; do
    migration_name=$(basename "$migration_file")
    
    # Skip README and non-executable files  
    if [[ "$migration_name" == "README.md" ]] || [ ! -x "$migration_file" ]; then
        skipped_count=$((skipped_count + 1))
        continue
    fi
    
    # Check if this is an "always run" migration (.always.sh suffix)
    # These migrations run on every sync without marker tracking
    if [[ "$migration_file" != *.always.sh ]]; then
        # Standard marker check for one-shot migrations
        marker_file="$MARKER_DIR/$(basename "$migration_file" .sh).marker"
        mkdir -p "$(dirname "$marker_file")"

        if [ -f "$marker_file" ]; then
            echo "✓ $migration_name (skipped - already applied)"
            skipped_count=$((skipped_count + 1))
            continue
        fi
    fi
    
    # Execute migration script with output capture
    migration_output=$(mktemp)
    echo ""
    echo "=== $migration_name ==="
    
    if "$migration_file" >"$migration_output" 2>&1; then
        # Display migration output
        cat "$migration_output" 2>/dev/null || echo "(no output)"
        echo "✓ $migration_name completed"
        
        # Create marker file for one-shot migrations only (skip for .always.sh)
        if [[ "$migration_file" != *.always.sh ]]; then
            echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker_file"
            echo "Migration: $migration_name" >> "$marker_file"
            echo "Description: $(head -n 10 "$migration_file" | grep "^# Migration:" | head -1 | cut -d':' -f2- | xargs)" >> "$marker_file"
        fi
        
        rm -f "$migration_output"
        executed_count=$((executed_count + 1))
    else
        exit_code=$?
        # Display migration output on failure
        cat "$migration_output" 2>/dev/null || echo "(no output)"
        echo "✗ $migration_name failed (exit $exit_code)"
        rm -f "$migration_output"
        failed_count=$((failed_count + 1))
        exit $exit_code
    fi
    
done < <(find "$MIGRATIONS_DIR" -name "*.sh" -type f -print0 | sort -z)

# Summary
if [ "$executed_count" -gt 0 ] || [ "$skipped_count" -gt 0 ]; then
    echo "Migration summary: $executed_count completed, $skipped_count skipped"
fi

exit 0