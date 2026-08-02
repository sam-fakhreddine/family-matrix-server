#!/bin/bash
# Nightly family-matrix-server backup: postgres dump + media store snapshot.
# Destination comes from BACKUP_DIR in .env. Retention: 14 days.
# Install in cron (adjust user/time):
#   30 3 * * * /path/to/family-matrix-server/backup.sh >> /path/to/family-matrix-server/backup.log 2>&1
# NOTE: this keeps backups on the same machine — complete 3-2-1 by also
# pushing $BACKUP_DIR offsite (restic/kopia to B2/S3 recommended).
set -eu
umask 077   # dumps hold the full DB (incl. access tokens) — owner-only, always
cd "$(dirname "$0")"
set -a; . ./.env; set +a

TS=$(date +%Y-%m-%d)
# Lock lives in the repo dir, not /tmp: a world-writable /tmp path could be
# pre-created (or symlinked) by any local user.
LOCK=.backup.lock

exec 9>"$LOCK"  # FD 9 held open for process lifetime; flock uses it as the lock handle
flock -n 9 || { echo "$(date -Is) SKIP: backup already running"; exit 1; }  # -n: concurrent runs exit instead of queue

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# -F c = postgres custom format (compressed, supports selective pg_restore)
docker exec family-matrix-db-1 pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c -f /tmp/synapse-backup.dump
docker cp -q family-matrix-db-1:/tmp/synapse-backup.dump "$BACKUP_DIR/synapse-$TS.dump"  # -q: quiet for clean cron logs
docker exec family-matrix-db-1 rm -f /tmp/synapse-backup.dump
# docker cp preserves the in-container mode (644) — the dump holds every
# access token and message on the server, so clamp it despite the umask
chmod 600 "$BACKUP_DIR/synapse-$TS.dump"


tar czf "$BACKUP_DIR/media-$TS.tar.gz" -C ./files media_store

find "$BACKUP_DIR" -maxdepth 1 -name '*-*.dump' -mtime +14 -delete
find "$BACKUP_DIR" -maxdepth 1 -name 'media-*.tar.gz' -mtime +14 -delete

echo "$(date -Is) OK: synapse-$TS.dump ($(du -h "$BACKUP_DIR/synapse-$TS.dump" | cut -f1)) media-$TS.tar.gz"  # cut -f1: size column only
