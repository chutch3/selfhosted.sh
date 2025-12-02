# Database Backup Strategy

## Overview

This backup system provides the **best of both worlds**:
- ✅ **Local storage** for databases = fast performance, no gateway timeouts
- ✅ **Automated backups** to NAS = data safety and disaster recovery
- ✅ **Easy migration** between nodes using restore scripts

## Architecture

### Local Database Volumes
Databases run on local volumes for maximum performance:
- `photoprism_database` (MariaDB) → Node: mini
- `librechat_mongodb` (MongoDB) → Node: mini
- `librechat_vectordb` (PostgreSQL) → Node: mini
- `librechat_meilisearch` (MeiliSearch) → Node: mini

### Automated Backups
Backup services run daily and store compressed dumps on NAS:
- **Schedule**: Daily at 2 AM, 3 AM, 4 AM (staggered)
- **Retention**: 30 days
- **Storage**: NAS mount at `//${NAS_SERVER}/db_backups`
- **Format**: Compressed SQL dumps (.sql.gz) or native archives

## Deployment

### 1. Deploy Backup Services
```bash
cd /home/cody/workspace/homelab/stacks/backups
docker stack deploy -c docker-compose.yml backups
```

### 2. Verify Backups
```bash
# Check backup services are running
docker service ls | grep backup

# View backup logs
docker service logs -f backups_photoprism-db-backup

# List available backups
docker run --rm -v db_backups:/backups alpine ls -lh /backups/
```

## Restore Procedures

### PhotoPrism Database
```bash
cd /home/cody/workspace/homelab/stacks/backups

# List available backups
./restore-photoprism.sh

# Restore from specific backup
./restore-photoprism.sh photoprism_20250126_020000.sql.gz
```

### LibreChat MongoDB
```bash
cd /home/cody/workspace/homelab/stacks/backups

# List available backups
./restore-librechat-mongodb.sh

# Restore from specific backup
./restore-librechat-mongodb.sh librechat_mongodb_20250126_030000.archive
```

### LibreChat VectorDB (PostgreSQL)
```bash
cd /home/cody/workspace/homelab/stacks/backups

# List available backups
./restore-librechat-vectordb.sh

# Restore from specific backup
./restore-librechat-vectordb.sh librechat_vectordb_20250126_040000.sql.gz
```

## Migration to Another Node

If you need to move a database to a different node:

### Option 1: Using Backups (Recommended)
```bash
# 1. Create a fresh backup
docker service logs backups_photoprism-db-backup

# 2. Update node constraint in docker-compose.yml
# Change: node.labels.database == true
# To: node.hostname == new-node-name

# 3. Redeploy the service (will create new empty volume on new node)
docker stack deploy -c stacks/apps/photoprism/docker-compose.yml photoprism

# 4. Restore from backup
cd stacks/backups
./restore-photoprism.sh photoprism_YYYYMMDD_HHMMSS.sql.gz
```

### Option 2: Manual Volume Copy
```bash
# On source node
docker run --rm -v photoprism_database:/source -v /tmp:/backup alpine \
    tar czf /backup/photoprism_database.tar.gz -C /source .

# Copy to destination node
scp /tmp/photoprism_database.tar.gz user@new-node:/tmp/

# On destination node
docker volume create photoprism_database
docker run --rm -v photoprism_database:/dest -v /tmp:/backup alpine \
    tar xzf /backup/photoprism_database.tar.gz -C /dest
```

## Manual Backup

To create an immediate backup:

```bash
# PhotoPrism MariaDB
docker run --rm \
    --network traefik-public \
    -v db_backups:/backups \
    -e MYSQL_PWD="${PHOTOPRISM_DB_PASSWORD}" \
    mariadb:11 \
    mysqldump -h photoprism_mariadb -u photoprism photoprism | gzip > /backups/photoprism_manual_$(date +%Y%m%d_%H%M%S).sql.gz

# LibreChat MongoDB
docker run --rm \
    --network traefik-public \
    -v db_backups:/backups \
    mongo:latest \
    mongodump --host=librechat_mongodb --archive=/backups/librechat_mongodb_manual_$(date +%Y%m%d_%H%M%S).archive --gzip

# LibreChat VectorDB
docker run --rm \
    --network traefik-public \
    -v db_backups:/backups \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    ankane/pgvector:latest \
    pg_dump -h librechat_vectordb -U myuser mydatabase | gzip > /backups/librechat_vectordb_manual_$(date +%Y%m%d_%H%M%S).sql.gz
```

## Monitoring

### Check Backup Status
```bash
# View all backup services
docker service ls | grep backup

# Check last backup time
docker run --rm -v db_backups:/backups alpine ls -lht /backups/ | head -10

# Check backup sizes
docker run --rm -v db_backups:/backups alpine du -sh /backups/*
```

### Backup Health Checks
```bash
# Verify backups are running
docker service ps backups_photoprism-db-backup
docker service ps backups_librechat-mongodb-backup
docker service ps backups_librechat-vectordb-backup

# Check for errors
docker service logs --tail 50 backups_photoprism-db-backup
```

## Troubleshooting

### Backup Service Not Running
```bash
# Check service status
docker service ps backups_photoprism-db-backup --no-trunc

# View logs
docker service logs backups_photoprism-db-backup

# Restart service
docker service update --force backups_photoprism-db-backup
```

### No Backups Created
```bash
# Check NAS mount
docker run --rm -v db_backups:/backups alpine ls -l /backups/

# Check disk space
docker run --rm -v db_backups:/backups alpine df -h /backups/

# Manually trigger backup (see Manual Backup section)
```

### Restore Fails
```bash
# Verify backup file exists and is readable
docker run --rm -v db_backups:/backups alpine ls -lh /backups/<backup_file>

# Test backup integrity
gunzip -t /path/to/backup.sql.gz

# Check database service is running
docker service ps photoprism_mariadb
```

## Best Practices

1. **Monitor backups**: Check backup logs weekly to ensure they're running
2. **Test restores**: Perform test restores quarterly to verify backup integrity
3. **Before major changes**: Create manual backup before system updates or migrations
4. **Document configuration**: Keep .env file backed up separately (without secrets in git)
5. **Multiple retention points**: The 30-day retention gives you flexibility to restore from different points in time
