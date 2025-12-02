#!/bin/bash
# Restore LibreChat MongoDB from backup

set -e

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file.archive>"
    echo ""
    echo "Available backups:"
    docker run --rm -v db_backups:/backups alpine ls -lh /backups/librechat_mongodb_*.archive
    exit 1
fi

echo "========================================="
echo "LibreChat MongoDB Restore"
echo "========================================="
echo "Backup file: $BACKUP_FILE"
echo ""
read -r -p "This will REPLACE the current database. Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

echo ""
echo "Step 1: Stopping LibreChat services..."
docker service scale librechat_api=0

echo ""
echo "Step 2: Restoring database from backup..."
docker run --rm \
    --network traefik-public \
    -v db_backups:/backups \
    mongo:latest \
    mongorestore --host=librechat_mongodb --archive="/backups/$BACKUP_FILE" --gzip --drop

echo ""
echo "Step 3: Restarting LibreChat services..."
docker service scale librechat_api=1

echo ""
echo "========================================="
echo "Restore completed successfully!"
echo "========================================="
