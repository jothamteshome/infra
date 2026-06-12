#!/bin/bash
set -e

LATEST=$(ls -t /backups/*.tgz 2>/dev/null | head -1)
if [ -z "$LATEST" ]; then
  echo "No backup file found, skipping S3 upload"
  exit 0
fi

DATE=$(date +%Y-%m-%d)
DEST="aws:$BACKUP_S3_BUCKET/vanilla/$LEVEL/$DATE.tgz"

echo "Uploading $LATEST to $DEST"
rclone copyto "$LATEST" "$DEST" \
  --metadata-set "minecraft-version=$VERSION" \
  --metadata-set "level=$LEVEL"
echo "Upload complete"