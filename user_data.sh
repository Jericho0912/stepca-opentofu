#!/usr/bin/env bash
# =============================================================================
# Production Bootstrap Script: Smallstep CA & FreeRADIUS on AWS Nitro (t4g.micro)
# Target OS: Ubuntu 24.04 LTS Minimal (ARM64)
# =============================================================================

set -euo pipefail

# Redirect all stdout and stderr to syslog and dedicated log file
exec > >(tee -a /var/log/pki-bootstrap.log | logger -t pki-bootstrap -s 2>/dev/console) 2>&1

echo "========================================================================"
echo "Starting PKI & RADIUS MicroVM Bootstrap - $(date -u --iso-8601=seconds)"
echo "========================================================================"

# Prevent interactive prompts during apt operations
export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 1. Update OS and Install Base Tooling
# -----------------------------------------------------------------------------
echo "[1/6] Updating APT repositories and installing baseline dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  nvme-cli \
  e2fsprogs \
  jq \
  tar \
  qemu-user-static \
  binfmt-support

# -----------------------------------------------------------------------------
# 2. Nitro NVMe EBS Volume Discovery, Formatting & Resilient Mounting
# -----------------------------------------------------------------------------
echo "[2/6] Detecting and mounting decoupled encrypted EBS volume..."

EBS_VOL_ID="${ebs_volume_id}"
# Strip hyphen to match AWS Nitro NVMe serial convention (e.g. vol0123456789abcdef0)
EBS_VOL_ID_STRIP="$${EBS_VOL_ID//-/}"
MOUNT_DIR="/mnt/step-ca"
TARGET_DEV=""

echo "Searching for EBS volume $EBS_VOL_ID ($EBS_VOL_ID_STRIP)..."

# Poll up to 60 seconds for asynchronous EBS volume attachment
for i in $(seq 1 30); do
  # Check 1: Nitro NVMe by-id link
  if [ -e "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$${EBS_VOL_ID_STRIP}" ]; then
    TARGET_DEV=$(realpath "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$${EBS_VOL_ID_STRIP}")
    echo "Found block device via Nitro by-id: $TARGET_DEV"
    break
  fi

  # Check 2: Standard block device fallback (/dev/sdf or /dev/xvdf)
  if [ -b "/dev/sdf" ]; then
    TARGET_DEV="/dev/sdf"
    break
  elif [ -b "/dev/xvdf" ]; then
    TARGET_DEV="/dev/xvdf"
    break
  fi

  # Check 3: Query nvme list for serial number match
  NVME_MATCH=$(nvme list -o json 2>/dev/null | jq -r --arg vol "$${EBS_VOL_ID_STRIP}" '.Devices[] | select(.SerialNumber == $vol) | .DevicePath' || true)
  if [ -n "$NVME_MATCH" ] && [ -b "$NVME_MATCH" ]; then
    TARGET_DEV="$NVME_MATCH"
    echo "Found block device via nvme list: $TARGET_DEV"
    break
  fi

  # Check 4: Unpartitioned secondary NVMe disk (excluding root nvme0n1)
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

echo "Target storage block device identified: $TARGET_DEV"

# Check if filesystem already exists (Safe for instance rebuilds: PREVENTS DATA LOSS)
FS_TYPE=$(blkid -o value -s TYPE "$TARGET_DEV" || true)
if [ -z "$FS_TYPE" ]; then
  echo "No existing filesystem detected on $TARGET_DEV. Formatting with ext4..."
  mkfs.ext4 -F -L step-ca-data "$TARGET_DEV"
else
  echo "Existing $FS_TYPE filesystem detected on $TARGET_DEV. Preserving cryptographic keys."
fi

# Prepare mount directory
mkdir -p "$MOUNT_DIR"

# Mount by UUID in /etc/fstab for boot resilience (nofail prevents boot hangs if detached)
DEV_UUID=$(blkid -o value -s UUID "$TARGET_DEV")
if ! grep -q "$DEV_UUID" /etc/fstab; then
  echo "UUID=$DEV_UUID $MOUNT_DIR ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
fi

mount -a

# Verify mount
if ! mountpoint -q "$MOUNT_DIR"; then
  echo "FATAL: Mount point $MOUNT_DIR is not active!" >&2
  exit 1
fi

echo "Decoupled EBS volume successfully mounted at $MOUNT_DIR."

# Initialize subdirectories
mkdir -p "$MOUNT_DIR/step"
mkdir -p "$MOUNT_DIR/freeradius"

# Smallstep container runs as user 'step' (UID 1000 / GID 1000)
chown -R 1000:1000 "$MOUNT_DIR/step"
chmod 700 "$MOUNT_DIR/step"

# -----------------------------------------------------------------------------
# 3. Install Official Docker Community Engine
# -----------------------------------------------------------------------------
echo "[3/6] Installing Docker Engine & Compose Plugin..."

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
# 4. Bootstrap FreeRADIUS Base Configuration
# -----------------------------------------------------------------------------
echo "[4/6] Bootstrapping FreeRADIUS configuration template on persistent volume..."

# If persistent freeradius dir is empty, extract clean base config from image
if [ ! -f "$MOUNT_DIR/freeradius/radiusd.conf" ]; then
  echo "Extracting default FreeRADIUS configuration from container..."
  docker run --rm freeradius/freeradius-server:latest tar -C /etc/freeradius -cf - . | tar -C "$MOUNT_DIR/freeradius" -xf -
  
  # Configure clients.conf with dynamic internal VPC RADIUS secret
  cat << 'EOF_CLIENTS' >> "$MOUNT_DIR/freeradius/clients.conf"

# ---------------------------------------------------------
# Dynamic Internal Subnet Access Point Configuration
# ---------------------------------------------------------
client internal_networks {
  ipaddr = 0.0.0.0/0
  proto = *
  secret = ${radius_secret}
  require_message_authenticator = no
  nas_type = other
}
EOF_CLIENTS

  echo "FreeRADIUS configuration initialized."
fi

# -----------------------------------------------------------------------------
# 5. Provision Dynamic Docker Compose Stack
# -----------------------------------------------------------------------------
echo "[5/6] Generating Docker Compose configuration..."

STACK_DIR="/opt/pki-radius"
mkdir -p "$STACK_DIR"

cat << 'EOF_COMPOSE' > "$STACK_DIR/docker-compose.yml"
services:
  step-ca:
    image: smallstep/step-ca:latest
    container_name: step-ca
    restart: unless-stopped
    ports:
      # Step-CA listens internally on 9000; map directly to host port 443
      - "443:9000"
    environment:
      - DOCKER_STEP_CA_INIT=true
      - STEP_CA_NAME=${ca_name}
      - STEP_CA_DNS=${ca_dns}
      - STEP_CA_PASSWORD=${ca_password}
    volumes:
      - /mnt/step-ca/step:/home/step
    healthcheck:
      test: ["CMD", "step", "ca", "health", "--ca-url", "https://localhost:9000", "--root", "/home/step/certs/root_ca.crt"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  freeradius:
    image: freeradius/freeradius-server:latest
    container_name: freeradius
    restart: unless-stopped
    ports:
      - "1812:1812/udp"
      - "1813:1813/udp"
    volumes:
      - /mnt/step-ca/freeradius:/etc/freeradius
    depends_on:
      - step-ca
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF_COMPOSE

# -----------------------------------------------------------------------------
# 6. Establish Systemd Service & Launch Containers
# -----------------------------------------------------------------------------
echo "[6/6] Establishing systemd service unit and launching stack..."

cat << 'EOF_SERVICE' > /etc/systemd/system/pki-radius.service
[Unit]
Description=PKI Step-CA and FreeRADIUS Production Stack
RequiresMountsFor=/mnt/step-ca
Requires=docker.service
After=docker.service mnt-step\\x2dca.mount

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/pki-radius
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable pki-radius.service
systemctl start pki-radius.service

echo "========================================================================"
echo "PKI & RADIUS Stack Bootstrap Completed Successfully!"
echo "Timestamp: $(date -u --iso-8601=seconds)"
echo "========================================================================"
touch /var/log/pki-bootstrap-complete.marker
