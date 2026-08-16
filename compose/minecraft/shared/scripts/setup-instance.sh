#!/bin/bash
# setup-instance.sh — Minecraft EC2 instance setup
#
# Usage:
#   setup-instance.sh <server-type>   (required on first run)
#   setup-instance.sh                 (subsequent runs — reads SERVER_TYPE
#                                       from /etc/environment)
#
#   e.g. setup-instance.sh vanilla
#
# Idempotent. Self-updating — pulls latest from the repo first thing,
# so it can be triggered either by the GitHub Actions deploy workflow
# (when the instance is running) or manually via SSH (anytime,
# including after the instance was stopped when the workflow couldn't
# reach it). Also runs on every boot via the minecraft-setup systemd
# service, which is what keeps the Route53 A record correct regardless
# of *why* the instance booted (Lambda trigger, manual start, AWS
# maintenance reboot, etc) — DNS truth lives with the instance, not
# with whatever triggered the boot.
#
# Instance profile needs:
#   ssm:GetParameter, ec2:StopInstances,
#   route53:ChangeResourceRecordSets, s3:PutObject/ListBucket (for backups)

set -euo pipefail

# SERVER_TYPE identifies which instance this is — "vanilla", "modded", etc.
# Determines which compose/minecraft/<server-type>/.env.mc to use and
# which /minecraft/<server-type>/... SSM params to fetch.
#
# Required on first run, persisted to /etc/environment afterward so
# subsequent runs (deploy workflow, manual SSH, every-boot systemd
# service) don't need to pass it.
if [ -n "${1:-}" ]; then
    SERVER_TYPE="$1"
    if ! grep -q "^SERVER_TYPE=" /etc/environment 2>/dev/null; then
        echo "SERVER_TYPE=$SERVER_TYPE" >> /etc/environment
    fi
elif grep -q "^SERVER_TYPE=" /etc/environment 2>/dev/null; then
    SERVER_TYPE=$(grep "^SERVER_TYPE=" /etc/environment | cut -d= -f2)
else
    echo "Usage: setup-instance.sh <server-type> (required on first run)" >&2
    exit 1
fi

INFRA_DIR="/opt/infra"
SHARED_DIR="$INFRA_DIR/compose/minecraft/shared"
SERVER_DIR="$INFRA_DIR/compose/minecraft/$SERVER_TYPE"
AWS_REGION="us-east-2"

log() { echo "[setup-instance] $*"; }

get_param() {
    aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$1" \
        --with-decryption \
        --query Parameter.Value \
        --output text
}

# Bounded retry — for transient failures (network blip, AWS throttling),
# not for waiting on eventual consistency.
retry() {
    local attempts="$1"; shift
    local delay="$1"; shift
    local description="$1"; shift

    for attempt in $(seq 1 "$attempts"); do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            log "$description failed (attempt $attempt/$attempts), retrying in ${delay}s..."
            sleep "$delay"
        fi
    done
    log "$description failed after $attempts attempts"
    return 1
}

# ---------------------------------------------------------------
# 1. Self-update — pull latest from repo
# ---------------------------------------------------------------
log "=== Pulling latest from repo ==="
git config --system --add safe.directory "$INFRA_DIR"

BEFORE_SHA=$(git -C "$INFRA_DIR" rev-parse HEAD)
git -C "$INFRA_DIR" fetch origin main
git -C "$INFRA_DIR" reset --hard origin/main
AFTER_SHA=$(git -C "$INFRA_DIR" rev-parse HEAD)

# CRITICAL: if this script's own file just changed on disk, bash is
# still reading from its original buffered copy of the OLD file —
# it does NOT reload mid-execution. Continuing past this point would
# run a mix of old/new code depending on byte offsets, which is unsafe
# and has caused real failures (stale logic executing after a fix was
# already pulled). Re-exec fresh from disk so everything after this
# line is guaranteed to come from the file that's actually there now.
if [ "$BEFORE_SHA" != "$AFTER_SHA" ]; then
    log "Repo updated ($BEFORE_SHA -> $AFTER_SHA) — re-executing fresh copy of this script"
    exec bash "$SHARED_DIR/scripts/setup-instance.sh" "$SERVER_TYPE"
fi

# ---------------------------------------------------------------
# 2. Docker
# AL2023's default repo only has plain `docker`, NOT
# docker-compose-plugin — that package doesn't exist there. Compose
# v2 has to be installed manually as a CLI plugin binary. Installed
# system-wide (/usr/local/lib/docker/cli-plugins) so it works for
# both ec2-user and root (root needs it too, since systemd services
# run docker compose commands as root).
# ---------------------------------------------------------------
log "=== Installing Docker ==="
if ! command -v docker &>/dev/null; then
    dnf install -y docker
    systemctl enable docker
    systemctl start docker
else
    log "Docker already installed, skipping"
fi
usermod -aG docker ec2-user

log "=== Installing Docker Compose plugin ==="
if ! docker compose version &>/dev/null; then
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    log "Docker Compose plugin installed: $(docker compose version)"
else
    log "Docker Compose plugin already installed, skipping"
fi

# ---------------------------------------------------------------
# 3. Swap (2GB — Java heap benefits on 4GB instance)
# ---------------------------------------------------------------
log "=== Configuring swap (2GB) ==="
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p
    log "Swap configured"
else
    log "Swap already configured, skipping"
fi

# ---------------------------------------------------------------
# 4. Directories
# ---------------------------------------------------------------
log "=== Creating directories ==="
mkdir -p /opt/minecraft/server /opt/minecraft/backups
# itzg runs as uid 1000 — needs write access to server directory
chown -R 1000:1000 /opt/minecraft/server /opt/minecraft/backups

# ---------------------------------------------------------------
# 5. Script permissions
# ---------------------------------------------------------------
log "=== Setting script permissions ==="
chmod +x "$SHARED_DIR/scripts/"*.sh

# ---------------------------------------------------------------
# 6. Symlink .env.mc so compose always reads from server type dir
# ---------------------------------------------------------------
log "=== Symlinking .env.mc for $SERVER_TYPE ==="
ln -sf "$SERVER_DIR/.env.mc" "$SHARED_DIR/.env.mc"

# ---------------------------------------------------------------
# 7. /etc/profile.d/init-env.sh
#    Same pattern as perpetual-app-host's init-env.sh — auto-loaded
#    on login shells, and sourced by the idle-shutdown systemd service
#    before it runs. Fetches secrets from SSM dynamically at source
#    time. SERVER_TYPE and AWS_REGION are non-secret and baked in here
#    as literals at write time.
# ---------------------------------------------------------------
log "=== Writing /etc/profile.d/init-env.sh ==="
cat > /etc/profile.d/init-env.sh << EOF
#!/bin/bash
# Auto-loaded on login shells (SSH, Instance Connect) and sourced by
# the minecraft-idle-shutdown systemd service.
# Fetches Minecraft ($SERVER_TYPE) environment variables from SSM.

export SERVER_TYPE="$SERVER_TYPE"
export REGION="$AWS_REGION"

echo "Fetching Minecraft ($SERVER_TYPE) environment variables from AWS SSM..."

export RCON_PASSWORD=\$(aws ssm get-parameter \\
    --name "/minecraft/$SERVER_TYPE/rcon-password" \\
    --with-decryption --query Parameter.Value \\
    --output text --region $AWS_REGION 2>/dev/null)

export BACKUP_S3_BUCKET=\$(aws ssm get-parameter \\
    --name "/minecraft/$SERVER_TYPE/backup-s3-bucket" \\
    --query Parameter.Value \\
    --output text --region $AWS_REGION 2>/dev/null)

export HOSTED_ZONE_ID=\$(aws ssm get-parameter \\
    --name "/minecraft/$SERVER_TYPE/hosted-zone-id" \\
    --query Parameter.Value \\
    --output text --region $AWS_REGION 2>/dev/null)

export MC_HOSTNAME=\$(aws ssm get-parameter \\
    --name "/minecraft/$SERVER_TYPE/hostname" \\
    --query Parameter.Value \\
    --output text --region $AWS_REGION 2>/dev/null)

export JAVA_VERSION=\$(aws ssm get-parameter \\
    --name "/minecraft/$SERVER_TYPE/java-version" \\
    --query Parameter.Value \\
    --output text --region $AWS_REGION 2>/dev/null || echo "")

echo "Minecraft environment loaded!"
EOF
chmod +x /etc/profile.d/init-env.sh

# ---------------------------------------------------------------
# 8. Self-register public IP with Route53
#    Runs on EVERY boot, regardless of why the instance started
#    (Lambda trigger, manual start, AWS maintenance reboot). This
#    is what replaced the Lambda's old EIP-allocation responsibility
#    — DNS truth now lives with the instance itself, not with
#    whatever triggered the boot. Uses IMDSv2 (token required).
# ---------------------------------------------------------------
log "=== Registering public IP with Route53 ==="
source /etc/profile.d/init-env.sh

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4)

if [ -z "$PUBLIC_IP" ]; then
    log "WARNING: could not determine public IP — skipping Route53 update"
else
    log "Public IP: $PUBLIC_IP — updating $MC_HOSTNAME"
    register_route53() {
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
                        \"ResourceRecords\": [{\"Value\": \"$PUBLIC_IP\"}]
                    }
                }]
            }"
    }
    if retry 3 5 "Route53 registration" register_route53; then
        log "Route53 updated: $MC_HOSTNAME -> $PUBLIC_IP"
    else
        log "WARNING: Route53 registration failed after retries — DNS may be stale until next boot/run"
    fi
fi

# ---------------------------------------------------------------
# 9. Systemd — idle-shutdown service
#    Containers use `restart: unless-stopped` and survive reboots
#    with their last-applied env baked in by Docker — no boot-time
#    compose service required.
# ---------------------------------------------------------------
log "=== Installing minecraft-idle-shutdown service ==="
cat > /etc/systemd/system/minecraft-idle-shutdown.service << EOF
[Unit]
Description=Minecraft idle shutdown monitor ($SERVER_TYPE)
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'source /etc/profile.d/init-env.sh && exec $SHARED_DIR/scripts/idle-shutdown.sh'
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------
# 10. Systemd — minecraft-setup service (runs this script on every boot)
#     Refreshes git checkout, SSM-backed init-env.sh, Route53 A record,
#     and idle-shutdown service config on every start. Does NOT touch
#     containers — restart: unless-stopped already brought them up
#     with last-known config independently, so a failure here doesn't
#     affect the running server. Apply new container config manually
#     via `docker compose up -d` after this runs.
# ---------------------------------------------------------------
log "=== Installing minecraft-setup service ==="
cat > /etc/systemd/system/minecraft-setup.service << EOF
[Unit]
Description=Minecraft instance config refresh ($SERVER_TYPE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $SHARED_DIR/scripts/setup-instance.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minecraft-idle-shutdown.service
systemctl enable minecraft-setup.service
systemctl restart minecraft-idle-shutdown || true

log "=== Setup complete ==="
log ""
log "Config refreshed. To apply changes to running containers:"
log "  source /etc/profile.d/init-env.sh"
log "  cd $SHARED_DIR"
log "  docker compose up -d"
log "  docker image prune -f"