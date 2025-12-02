#!/bin/bash
# Restore PhotoPrism MariaDB from backup

set -e

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file.sql.gz>"
    echo ""
    echo "Available backups:"
    docker run --rm -v db_backups:/backups alpine ls -lh /backups/photoprism_*.sql.gz
    exit 1
fi

echo "========================================="
echo "PhotoPrism Database Restore"
echo "========================================="
echo "Backup file: $BACKUP_FILE"
echo ""
read -r -p "This will REPLACE the current database. Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

echo ""
echo "Step 1: Stopping PhotoPrism service..."
docker service scale photoprism_photoprism=0

echo ""
echo "Step 2: Restoring database from backup..."
docker run --rm \
    --network traefik-public \
    -v db_backups:/backups \
    -e MYSQL_PWD="${PHOTOPRISM_DB_PASSWORD}" \
    mariadb:11 \
    bash -c "gunzip < /backups/$BACKUP_FILE | mysql -h photoprism_mariadb -u photoprism photoprism"

echo ""
echo "Step 3: Restarting PhotoPrism service..."
docker service scale photoprism_photoprism=1

echo ""
echo "========================================="
echo "Restore completed successfully!"
echo "========================================="
