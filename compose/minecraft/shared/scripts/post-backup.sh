#!/bin/bash
set -e

LATEST=$(ls -t /backups/*.tar.gz 2>/dev/null | head -1)
if [ -z "$LATEST" ]; then
    echo "[post-backup] No backup file found, skipping S3 upload"
    exit 0
fi

DATE=$(date +%Y-%m-%d)
DEST="aws:$BACKUP_S3_BUCKET/vanilla/$LEVEL/$DATE.tgz"

echo "[post-backup] Uploading $LATEST to $DEST"

if rclone copyto "$LATEST" "$DEST" \
    --s3-no-head \
    --metadata-set "minecraft-version=$VERSION" \
    --metadata-set "level=$LEVEL"; then
    echo "[post-backup] Upload complete"
else
    echo "[post-backup] WARNING: upload failed — will retry on next backup cycle"
fi