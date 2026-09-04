#!/usr/bin/env bash
# =============================================================================
# Bootstrap Script: AnythingLLM + Caddy Reverse Proxy on AWS Graviton (t4g.small)
# Target OS: Ubuntu 24.04 LTS Minimal (ARM64)
# =============================================================================

set -euo pipefail

exec > >(tee -a /var/log/anythingllm-bootstrap.log | logger -t anythingllm-bootstrap -s 2>/dev/console) 2>&1

echo "========================================================================"
echo "Starting AnythingLLM Stack Bootstrap - $(date -u --iso-8601=seconds)"
echo "========================================================================"

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Update OS and Install Base Utilities
# -----------------------------------------------------------------------------
echo "[1/5] Installing base system dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  nvme-cli \
  e2fsprogs \
  jq

# -----------------------------------------------------------------------------
# 2. Nitro NVMe EBS Volume Discovery & Mount
# -----------------------------------------------------------------------------
echo "[2/5] Detecting and mounting decoupled EBS storage..."

EBS_VOL_ID="${ebs_volume_id}"
EBS_VOL_ID_STRIP="$${EBS_VOL_ID//-/}"
MOUNT_DIR="/mnt/anythingllm"
TARGET_DEV=""

for i in $(seq 1 30); do
  if [ -e "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$${EBS_VOL_ID_STRIP}" ]; then
    TARGET_DEV=$(realpath "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$${EBS_VOL_ID_STRIP}")
    echo "Found block device via Nitro by-id: $TARGET_DEV"
    break
  fi

  if [ -b "/dev/sdf" ]; then
    TARGET_DEV="/dev/sdf"
    break
  elif [ -b "/dev/xvdf" ]; then
    TARGET_DEV="/dev/xvdf"
    break
  fi

  SECONDARY_DEV=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" && $1 !~ /^nvme0/ {print "/dev/"$1}' | head -n 1)
  if [ -n "$SECONDARY_DEV" ] && [ -b "$SECONDARY_DEV" ]; then
    TARGET_DEV="$SECONDARY_DEV"
    echo "Found secondary block device: $TARGET_DEV"
    break
  fi

  echo "Waiting for EBS attachment (attempt $i/30)..."
  sleep 2
done

if [ -z "$TARGET_DEV" ]; then
  echo "FATAL: Attached EBS volume $EBS_VOL_ID could not be located!" >&2
  exit 1
fi

echo "Block device identified: $TARGET_DEV"

# Safe formatting: Only format if filesystem does not already exist
FS_TYPE=$(blkid -o value -s TYPE "$TARGET_DEV" || true)
if [ -z "$FS_TYPE" ]; then
  echo "Formatting $TARGET_DEV with ext4..."
  mkfs.ext4 -F -L anythingllm-data "$TARGET_DEV"
else
  echo "Existing $FS_TYPE filesystem detected. Preserving data."
fi

mkdir -p "$MOUNT_DIR"
DEV_UUID=$(blkid -o value -s UUID "$TARGET_DEV")
if ! grep -q "$DEV_UUID" /etc/fstab; then
  echo "UUID=$DEV_UUID $MOUNT_DIR ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
fi

mount -a

mkdir -p "$MOUNT_DIR/storage"
mkdir -p "$MOUNT_DIR/caddy_data"
mkdir -p "$MOUNT_DIR/caddy_config"

# Grant write permissions for the container's internal non-root user
chmod -R 777 "$MOUNT_DIR/storage"

# -----------------------------------------------------------------------------
# 3. Install Docker Engine & Compose Plugin
# -----------------------------------------------------------------------------
echo "[3/5] Installing Docker Engine & Compose..."

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y --no-install-recommends \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

# -----------------------------------------------------------------------------
# 4. Generate Caddyfile & Docker Compose Stack
# -----------------------------------------------------------------------------
echo "[4/5] Provisioning Caddyfile and Docker Compose..."

STACK_DIR="/opt/anythingllm"
mkdir -p "$STACK_DIR"

DOMAIN="${domain_name}"

if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
  cat << EOF_CADDY > "$STACK_DIR/Caddyfile"
$DOMAIN {
    reverse_proxy anythingllm:3001
}
EOF_CADDY
else
  # Generate self-signed TLS certificate with SAN for IP address access
  PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$STACK_DIR/server.key" \
    -out "$STACK_DIR/server.crt" \
    -subj "/CN=$${PUBLIC_IP:-localhost}" \
    -addext "subjectAltName=IP:$${PUBLIC_IP:-127.0.0.1},IP:127.0.0.1,DNS:localhost"
  chmod 644 "$STACK_DIR/server.crt" "$STACK_DIR/server.key"

  cat << 'EOF_CADDY' > "$STACK_DIR/Caddyfile"
:80 {
    reverse_proxy anythingllm:3001
}

:443 {
    tls /etc/caddy/server.crt /etc/caddy/server.key
    reverse_proxy anythingllm:3001
}
EOF_CADDY
fi

cat << 'EOF_COMPOSE' > "$STACK_DIR/docker-compose.yml"
services:
  anythingllm:
    image: mintplexlabs/anythingllm:latest
    container_name: anythingllm
    restart: unless-stopped
    volumes:
      - /mnt/anythingllm/storage:/app/server/storage
    environment:
      - SERVER_PORT=3001
      - STORAGE_DIR=/app/server/storage
    expose:
      - "3001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3001/api/ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "15m"
        max-file: "3"

  caddy-proxy:
    image: caddy:alpine
    container_name: caddy-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/anythingllm/Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/anythingllm/server.crt:/etc/caddy/server.crt:ro
      - /opt/anythingllm/server.key:/etc/caddy/server.key:ro
      - /mnt/anythingllm/caddy_data:/data
      - /mnt/anythingllm/caddy_config:/config
    depends_on:
      - anythingllm
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF_COMPOSE

# -----------------------------------------------------------------------------
# 5. Establish Systemd Service & Start Stack
# -----------------------------------------------------------------------------
echo "[5/5] Launching AnythingLLM systemd service..."

cat << 'EOF_SERVICE' > /etc/systemd/system/anythingllm.service
[Unit]
Description=AnythingLLM Production Stack
RequiresMountsFor=/mnt/anythingllm
Requires=docker.service
After=docker.service mnt-anythingllm.mount

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/anythingllm
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable anythingllm.service
systemctl start anythingllm.service

echo "========================================================================"
echo "AnythingLLM Bootstrap Completed Successfully!"
echo "Timestamp: $(date -u --iso-8601=seconds)"
echo "========================================================================"
touch /var/log/anythingllm-bootstrap-complete.marker
