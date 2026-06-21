#!/bin/bash
# idle-shutdown.sh — stops EC2 instance when no players online
#
# Reads from /etc/profile.d/init-env.sh (sourced by the systemd
# service before this script runs):
#   HOSTED_ZONE_ID, MC_HOSTNAME, REGION, SERVER_TYPE
#
# Flow on idle threshold:
#   1. Update Route53 A record to 0.0.0.0 (new connections stop here
#      first; the instance's own auto-assigned public IP is released
#      automatically by AWS when the instance stops — no EIP to
#      manage, nothing to release manually)
#   2. Trigger final backup via mc-backup (RCON is local; S3 upload
#      still needs internet, so this runs BEFORE stopping)
#   3. Stop EC2 instance

set -euo pipefail

# Fail loudly if init-env.sh didn't export these correctly, rather
# than failing silently partway through a shutdown.
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID not set — was init-env.sh sourced correctly?}"
: "${MC_HOSTNAME:?MC_HOSTNAME not set}"
: "${REGION:?REGION not set}"

POLL_INTERVAL=300    # seconds between checks (5 minutes)
IDLE_THRESHOLD=3     # consecutive zero-player checks before shutdown (15 minutes)
STARTUP_GRACE=300    # seconds to wait before first poll (server startup time)

idle_count=0

log() { logger -t minecraft-idle-shutdown "$*"; echo "[idle-shutdown] $*"; }

log "Startup grace period: waiting ${STARTUP_GRACE}s before polling..."
sleep "$STARTUP_GRACE"

log "Starting idle monitoring (poll every ${POLL_INTERVAL}s, threshold ${IDLE_THRESHOLD} checks)"

while true; do
    # Query player count via rcon-cli (included in itzg image)
    player_output=$(docker exec minecraft rcon-cli list 2>/dev/null || echo "")

    if [ -z "$player_output" ]; then
        log "Could not reach server via RCON — resetting idle count"
        idle_count=0
        sleep "$POLL_INTERVAL"
        continue
    fi

    players=$(echo "$player_output" | grep -oP '^\d+' || echo "0")

    if [ "$players" -gt 0 ]; then
        log "Players online: $players — resetting idle count"
        idle_count=0
    else
        idle_count=$((idle_count + 1))
        log "No players online (idle check $idle_count/$IDLE_THRESHOLD)"
    fi

    if [ "$idle_count" -ge "$IDLE_THRESHOLD" ]; then
        idle_minutes=$(( IDLE_THRESHOLD * POLL_INTERVAL / 60 ))
        log "Server idle for ${idle_minutes} minutes — initiating shutdown"

        # --- IMDSv2 ---
        TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
        INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/instance-id)
        log "Instance ID: $INSTANCE_ID"

        # --- Clear Route53 first ---
        # Set to 0.0.0.0 immediately so new connection attempts stop
        # here rather than racing the backup/shutdown process.
        log "Clearing Route53 record for $MC_HOSTNAME..."
        aws route53 change-resource-record-sets \
            --region us-east-1 \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch "{
                \"Changes\": [{
                    \"Action\": \"UPSERT\",
                    \"ResourceRecordSet\": {
                        \"Name\": \"$MC_HOSTNAME\",
                        \"Type\": \"A\",
                        \"TTL\": 60,
                        \"ResourceRecords\": [{\"Value\": \"0.0.0.0\"}]
                    }
                }]
            }" || log "Route53 update failed (non-fatal)"

        # --- Final backup ---
        # RCON commands (save-all/save-off/save-on) are local over the
        # Docker network. rclone upload to S3 needs internet, which is
        # still available here since the instance hasn't stopped yet.
        log "Triggering final backup..."
        docker exec minecraft-backup backup now || log "Backup failed (non-fatal, startup backup covers this)"
        log "Backup complete"

        # --- Stop instance ---
        # The auto-assigned public IP is released automatically by AWS
        # when the instance enters 'stopped' state — no manual cleanup.
        log "Stopping instance $INSTANCE_ID"
        aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID"

        log "Shutdown initiated. Goodbye."
        exit 0
    fi

    sleep "$POLL_INTERVAL"
done