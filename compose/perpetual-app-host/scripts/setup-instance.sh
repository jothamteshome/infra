#!/bin/bash
set -e

INFRA_DIR="/opt/infra"
COMPOSE_DIR="$INFRA_DIR/compose/perpetual-app-host"
AWS_REGION="us-east-1"

echo "=== Installing Docker ==="
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
else
    echo "Docker already installed, skipping"
fi

# Allow ubuntu user to run docker without sudo
usermod -aG docker ubuntu

echo "=== Installing AWS CLI v2 ==="
if ! command -v aws &>/dev/null; then
    apt-get install -y --no-install-recommends unzip
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
else
    echo "AWS CLI already installed, skipping"
fi

echo "=== Installing Certbot ==="
if ! command -v certbot &>/dev/null; then
    apt-get install -y certbot
else
    echo "Certbot already installed, skipping"
fi

echo "=== Disabling systemd-resolved stub listener (frees port 53 for PiHole) ==="
if [ ! -f /etc/systemd/resolved.conf.d/no-stub.conf ]; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf "[Resolve]\nDNSStubListener=no\n" > /etc/systemd/resolved.conf.d/no-stub.conf
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    echo "Stub listener disabled"
else
    echo "Stub listener already disabled, skipping"
fi

echo "=== Configuring swap (1GB) ==="
if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p
    echo "Swap configured"
else
    echo "Swap already configured, skipping"
fi

echo "=== Loading WireGuard kernel module ==="
if ! lsmod | grep -q wireguard; then
    modprobe wireguard
fi
if ! grep -q wireguard /etc/modules-load.d/wireguard.conf 2>/dev/null; then
    echo wireguard > /etc/modules-load.d/wireguard.conf
fi
echo "WireGuard kernel module loaded and configured for boot"

# Set up certbot auto-renewal cron if not already present
(crontab -l 2>/dev/null | grep -v certbot; echo "0 3 * * * docker stop nginx && certbot renew --quiet ; docker start nginx") | crontab -
echo "Certbot renewal cron set"

# Set up DB backup cron if not already present
if ! crontab -l 2>/dev/null | grep -q backup-db; then
    (crontab -l 2>/dev/null; echo "0 2 * * * bash /opt/infra/compose/perpetual-app-host/scripts/backup-db.sh >> /var/log/db-backup.log 2>&1") | crontab -
    echo "DB backup cron added"
fi

echo "=== Writing /etc/profile.d/init-env.sh ==="
cat > /etc/profile.d/init-env.sh <<'EOF'
#!/bin/bash
# Auto-loaded on every login shell (Instance Connect, SSH)
# Fetches shared infrastructure secrets from SSM into the current session
# Shared infrastructure
echo "Fetching shared infrastructure environment variables from AWS SSM..."
export POSTGRES_USER=$(aws ssm get-parameter --name "/perpetual-app-host/db/username" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export POSTGRES_PASSWORD=$(aws ssm get-parameter --name "/perpetual-app-host/db/password" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)

# whymighta
echo "Fetching whymighta environment variables from AWS SSM..."
export WHYMIGHTA_DB_USERNAME=$(aws ssm get-parameter --name "/whymighta/db/username" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_DB_PASSWORD=$(aws ssm get-parameter --name "/whymighta/db/password" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_DB_HOST=$(aws ssm get-parameter --name "/whymighta/db/host" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_DB_PORT=$(aws ssm get-parameter --name "/whymighta/db/port" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_DB_DATABASE=$(aws ssm get-parameter --name "/whymighta/db/database" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_OPENAI_API_KEY=$(aws ssm get-parameter --name "/whymighta/api/openai/key" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_ANTHROPIC_API_KEY=$(aws ssm get-parameter --name "/whymighta/api/anthropic/key" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_OPENAI_MODEL=$(aws ssm get-parameter --name "/whymighta/llm/openai/model" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_ANTHROPIC_MODEL=$(aws ssm get-parameter --name "/whymighta/llm/anthropic/model" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_WEATHER_API_KEY=$(aws ssm get-parameter --name "/whymighta/api/weather/key" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WHYMIGHTA_DISCORD_TOKEN=$(aws ssm get-parameter --name "/whymighta/discord/token" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)

# watch-together
echo "Fetching Watch Together environment variables from AWS SSM..."
export WATCH_TOGETHER_BACKEND_PORT=$(aws ssm get-parameter --name "/watch-together/backend/port" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WATCH_TOGETHER_YOUTUBE_API_KEY=$(aws ssm get-parameter --name "/watch-together/backend/youtube/api/key" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)

# pihole
echo "Fetching PiHole environment variables from AWS SSM..."
export PIHOLE_WEBPASSWORD=$(aws ssm get-parameter --name "/perpetual-app-host/pihole/webpassword" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)

# wireguard
echo "Fetching WireGuard environment variables from AWS SSM..."
export WIREGUARD_SERVERURL=$(aws ssm get-parameter --name "/perpetual-app-host/wireguard/serverurl" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)
export WIREGUARD_PEERS=$(aws ssm get-parameter --name "/perpetual-app-host/wireguard/peers" --with-decryption --query "Parameter.Value" --output text --region us-east-1 2>/dev/null)

echo "All environment variables loaded from SSM!"
EOF
chmod +x /etc/profile.d/init-env.sh

echo "=== Writing systemd service ==="
cat > /etc/systemd/system/perpetual-app-host.service <<'EOF'
[Unit]
Description=Perpetual App Host (Docker Compose)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/infra/compose/perpetual-app-host
ExecStart=/bin/bash -c 'source /etc/profile.d/init-env.sh && docker compose up -d'
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable perpetual-app-host.service

echo "=== Starting services ==="
systemctl start perpetual-app-host.service

echo "=== Waiting for PiHole to be ready ==="
until docker exec pihole pihole status 2>/dev/null | grep -q "FTL is listening"; do
    echo "Waiting for PiHole FTL..."
    sleep 5
done
echo "=== Running PiHole gravity update ==="
docker exec pihole pihole -g
echo "PiHole gravity update complete"

echo "=== Done ==="
echo "Run 'certbot certonly --nginx -d yourdomain.com' to issue SSL certificates"
