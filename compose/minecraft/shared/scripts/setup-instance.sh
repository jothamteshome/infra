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
# reach it).
#
# Instance profile needs:
#   ssm:GetParameter, ec2:StopInstances, ec2:DescribeAddresses,
#   ec2:DisassociateAddress, ec2:ReleaseAddresses,
#   route53:ChangeResourceRecordSets, s3:PutObject (for backups)

set -euo pipefail

# SERVER_TYPE identifies which instance this is — "vanilla", "modded", etc.
# Determines which compose/minecraft/<server-type>/.env.mc to use and
# which /minecraft/<server-type>/... SSM params to fetch.
#
# Required on first run, persisted to /etc/environment afterward so
# subsequent runs (deploy workflow, manual SSH) don't need to pass it.
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

INFRA_DIR="/opt/infra-hub"
SHARED_DIR="$INFRA_DIR/compose/minecraft/shared"
SERVER_DIR="$INFRA_DIR/compose/minecraft/$SERVER_TYPE"
AWS_REGION="us-east-2"

log() { echo "[setup-instance] $*"; }

# ---------------------------------------------------------------
# 1. Self-update — pull latest from repo
# ---------------------------------------------------------------
log "=== Pulling latest from repo ==="
git config --system --add safe.directory "$INFRA_DIR"
git -C "$INFRA_DIR" fetch origin main
git -C "$INFRA_DIR" reset --hard origin/main

# ---------------------------------------------------------------
# 2. Docker
# AL2023 has Docker in dnf — includes docker-compose-plugin for
# Compose v2. AWS CLI is pre-installed, no separate step needed.
# ---------------------------------------------------------------
log "=== Installing Docker ==="
if ! command -v docker &>/dev/null; then
    dnf install -y docker docker-compose-plugin
    systemctl enable docker
    systemctl start docker
else
    log "Docker already installed, skipping"
fi
usermod -aG docker ec2-user

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

echo "Minecraft environment loaded!"
EOF
chmod +x /etc/profile.d/init-env.sh

# ---------------------------------------------------------------
# 8. Systemd — idle-shutdown service
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
# 9. Systemd — minecraft-setup service (runs this script on every boot)
#    Refreshes git checkout, SSM-backed init-env.sh, and idle-shutdown
#    service config on every start. Does NOT touch containers —
#    restart: unless-stopped already brought them up with last-known
#    config independently, so a failure here doesn't affect the
#    running server. Apply new container config manually via
#    `docker compose up -d` after this runs.
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