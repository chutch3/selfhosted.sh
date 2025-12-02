#!/bin/bash
# Restore LibreChat VectorDB (PostgreSQL) from backup

set -e

BACKUP_FILE="$1"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup_file.sql.gz>"
    echo ""
    echo "Available backups:"
    docker run --rm -v db_backups:/backups alpine ls -lh /backups/librechat_vectordb_*.sql.gz
    exit 1
fi

echo "========================================="
echo "LibreChat VectorDB Restore"
echo "========================================="
echo "Backup file: $BACKUP_FILE"
echo ""
read -r -p "This will REPLACE the current database. Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

echo ""
echo "Step 1: Stopping dependent services..."
docker service scale librechat_api=0
docker service scale librechat_rag_api=0

echo ""
echo "Step 2: Restoring database from backup..."
docker run --rm \
    --network traefik-public \
    -v db_backups:/backups \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    ankane/pgvector:latest \
    bash -c "gunzip < /backups/$BACKUP_FILE | psql -h librechat_vectordb -U myuser -d mydatabase"

echo ""
echo "Step 3: Restarting services..."
docker service scale librechat_api=1
docker service scale librechat_rag_api=1

echo ""
echo "========================================="
echo "Restore completed successfully!"
echo "========================================="
