#!/usr/bin/env bash

# Docker Service Installation Script
# Runs inside the LXC container to install Docker and configure the service
#
# Arguments:
#   $1 - DOCKER_IMAGE (required)
#   $2 - DOCKER_PORTS (comma-separated, e.g., "80:80,443:443")
#   $3 - DOCKER_VOLUMES (comma-separated, e.g., "/data:/app/data")
#   $4 - DOCKER_ENV (comma-separated, e.g., "VAR1=val1,VAR2=val2")
#   $5 - DOCKER_RESTART (restart policy)
#   $6 - DOCKER_EXTRA_ARGS (additional docker run arguments)
#
# Copyright (c) 2024
# License: MIT

set -Eeuo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DOCKER_IMAGE="${1:-}"
DOCKER_PORTS="${2:-}"
DOCKER_VOLUMES="${3:-}"
DOCKER_ENV="${4:-}"
DOCKER_RESTART="${5:-unless-stopped}"
DOCKER_EXTRA_ARGS="${6:-}"

if [[ -z "$DOCKER_IMAGE" ]]; then
    echo "Error: Docker image is required"
    exit 1
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

msg_info() {
    echo -e " \e[36mℹ\e[0m \e[33m${1}...\e[0m"
}

msg_ok() {
    echo -e " \e[32m✓\e[0m \e[32m${1}\e[0m"
}

msg_error() {
    echo -e " \e[31m✗\e[0m \e[31m${1}\e[0m"
}

sanitize_name() {
    echo "$1" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | sed 's/:.*$//'
}

# =============================================================================
# SYSTEM PREPARATION
# =============================================================================

msg_info "Updating system packages"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq >/dev/null 2>&1
apt-get upgrade -y -qq >/dev/null 2>&1

msg_ok "System updated"

# =============================================================================
# INSTALL DEPENDENCIES
# =============================================================================

msg_info "Installing dependencies"

apt-get install -y -qq \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    jq \
    >/dev/null 2>&1

msg_ok "Dependencies installed"

# =============================================================================
# INSTALL DOCKER
# =============================================================================

msg_info "Installing Docker"

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
else
    OS_ID="debian"
    OS_VERSION_CODENAME="bookworm"
fi

# Handle Alpine differently
if [[ "$OS_ID" == "alpine" ]]; then
    apk add --no-cache docker docker-compose >/dev/null 2>&1
    rc-update add docker boot
    service docker start
else
    # Debian/Ubuntu installation
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
        ${OS_VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        >/dev/null 2>&1
fi

msg_ok "Docker installed"

# =============================================================================
# CONFIGURE DOCKER
# =============================================================================

msg_info "Configuring Docker"

# Create docker daemon configuration
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "journald",
    "log-opts": {
        "tag": "{{.Name}}"
    },
    "storage-driver": "overlay2"
}
EOF

# Enable and start Docker
systemctl enable docker >/dev/null 2>&1
systemctl start docker

# Wait for Docker to be ready
max_wait=30
waited=0
while ! docker info >/dev/null 2>&1; do
    sleep 1
    ((waited++))
    if [[ $waited -ge $max_wait ]]; then
        msg_error "Docker failed to start"
        exit 1
    fi
done

msg_ok "Docker configured and running"

# =============================================================================
# PULL DOCKER IMAGE
# =============================================================================

msg_info "Pulling Docker image: ${DOCKER_IMAGE}"

docker pull "${DOCKER_IMAGE}" >/dev/null 2>&1

msg_ok "Image pulled successfully"

# =============================================================================
# CREATE SERVICE
# =============================================================================

SERVICE_NAME=$(sanitize_name "$DOCKER_IMAGE")
CONTAINER_NAME="${SERVICE_NAME}"
SERVICE_FILE="/etc/systemd/system/docker-${SERVICE_NAME}.service"

msg_info "Creating systemd service: docker-${SERVICE_NAME}"

# Build docker run command
DOCKER_RUN_CMD="docker run --rm --name ${CONTAINER_NAME}"

# Add restart policy (for manual runs, systemd handles restart)
# Not adding --restart flag as systemd manages lifecycle

# Add port mappings
if [[ -n "$DOCKER_PORTS" ]]; then
    IFS=',' read -ra ports <<< "$DOCKER_PORTS"
    for port in "${ports[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        DOCKER_RUN_CMD+=" -p ${port}"
    done
fi

# Add volume mounts
if [[ -n "$DOCKER_VOLUMES" ]]; then
    IFS=',' read -ra volumes <<< "$DOCKER_VOLUMES"
    for volume in "${volumes[@]}"; do
        volume=$(echo "$volume" | tr -d ' ')
        # Create host directory if it doesn't exist
        host_path="${volume%%:*}"
        if [[ "$host_path" == /* ]]; then
            mkdir -p "$host_path"
        fi
        DOCKER_RUN_CMD+=" -v ${volume}"
    done
fi

# Add environment variables
if [[ -n "$DOCKER_ENV" ]]; then
    IFS=',' read -ra envs <<< "$DOCKER_ENV"
    for env in "${envs[@]}"; do
        env=$(echo "$env" | tr -d ' ')
        DOCKER_RUN_CMD+=" -e ${env}"
    done
fi

# Add extra arguments
if [[ -n "$DOCKER_EXTRA_ARGS" ]]; then
    DOCKER_RUN_CMD+=" ${DOCKER_EXTRA_ARGS}"
fi

# Add image
DOCKER_RUN_CMD+=" ${DOCKER_IMAGE}"

# Create systemd service file
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Docker Container Service - ${SERVICE_NAME}
Documentation=https://github.com/tebwritescode/docker-to-proxmox-lxc
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=${DOCKER_RESTART/unless-stopped/on-failure}
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=30

# Remove existing container if present
ExecStartPre=-/usr/bin/docker stop ${CONTAINER_NAME}
ExecStartPre=-/usr/bin/docker rm ${CONTAINER_NAME}

# Pull latest image on start (optional, comment out if not desired)
ExecStartPre=/usr/bin/docker pull ${DOCKER_IMAGE}

# Start the container
ExecStart=${DOCKER_RUN_CMD}

# Stop the container gracefully
ExecStop=/usr/bin/docker stop -t 30 ${CONTAINER_NAME}

# Send SIGKILL if container doesn't stop
KillMode=process
KillSignal=SIGINT

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=docker-${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

msg_ok "Service file created"

# =============================================================================
# SAVE CONFIGURATION
# =============================================================================

msg_info "Saving configuration"

cat > /etc/docker-service.conf <<EOF
# Docker Service Configuration
# Generated by docker-to-lxc installer

SERVICE_NAME="${SERVICE_NAME}"
DOCKER_IMAGE="${DOCKER_IMAGE}"
DOCKER_PORTS="${DOCKER_PORTS}"
DOCKER_VOLUMES="${DOCKER_VOLUMES}"
DOCKER_ENV="${DOCKER_ENV}"
DOCKER_RESTART="${DOCKER_RESTART}"
DOCKER_EXTRA_ARGS="${DOCKER_EXTRA_ARGS}"
INSTALLED_AT="$(date -Iseconds)"
EOF

msg_ok "Configuration saved"

# =============================================================================
# ENABLE AND START SERVICE
# =============================================================================

msg_info "Enabling and starting service"

systemctl daemon-reload
systemctl enable "docker-${SERVICE_NAME}" >/dev/null 2>&1
systemctl start "docker-${SERVICE_NAME}"

# Wait for service to be running
sleep 5

if systemctl is-active --quiet "docker-${SERVICE_NAME}"; then
    msg_ok "Service docker-${SERVICE_NAME} is running"
else
    msg_error "Service failed to start"
    echo ""
    echo "Service logs:"
    journalctl -u "docker-${SERVICE_NAME}" --no-pager -n 20
    echo ""
    echo "Docker logs:"
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -20 || true
    exit 1
fi

# =============================================================================
# CREATE HELPER SCRIPTS
# =============================================================================

msg_info "Creating helper scripts"

# Create update script
cat > /usr/local/bin/docker-service-update <<'EOFUPDATE'
#!/usr/bin/env bash
# Update the docker service

set -euo pipefail

source /etc/docker-service.conf

SERVICE="docker-${SERVICE_NAME}"

echo "Pulling latest image: ${DOCKER_IMAGE}"
docker pull "${DOCKER_IMAGE}"

echo "Restarting service..."
systemctl restart "${SERVICE}"

echo "Cleaning up old images..."
docker image prune -af

echo "Done! Service status:"
systemctl status "${SERVICE}" --no-pager
EOFUPDATE

chmod +x /usr/local/bin/docker-service-update

# Create logs script
cat > /usr/local/bin/docker-service-logs <<'EOFLOGS'
#!/usr/bin/env bash
# View docker service logs

source /etc/docker-service.conf

if [[ "${1:-}" == "-f" ]] || [[ "${1:-}" == "--follow" ]]; then
    docker logs -f "${SERVICE_NAME}"
else
    docker logs --tail 100 "${SERVICE_NAME}"
fi
EOFLOGS

chmod +x /usr/local/bin/docker-service-logs

# Create status script
cat > /usr/local/bin/docker-service-status <<'EOFSTATUS'
#!/usr/bin/env bash
# Show docker service status

source /etc/docker-service.conf

echo "=== Service Status ==="
systemctl status "docker-${SERVICE_NAME}" --no-pager

echo ""
echo "=== Container Status ==="
docker ps -a --filter "name=${SERVICE_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "=== Resource Usage ==="
docker stats "${SERVICE_NAME}" --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null || echo "Container not running"
EOFSTATUS

chmod +x /usr/local/bin/docker-service-status

msg_ok "Helper scripts created"

# =============================================================================
# CLEANUP
# =============================================================================

msg_info "Cleaning up"

apt-get autoremove -y -qq >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
rm -rf /var/lib/apt/lists/*

msg_ok "Installation complete"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "=============================================="
echo " Docker Service Installation Complete"
echo "=============================================="
echo ""
echo " Service:    docker-${SERVICE_NAME}"
echo " Image:      ${DOCKER_IMAGE}"
echo " Container:  ${SERVICE_NAME}"
echo ""
echo " Helper Commands:"
echo "   docker-service-status  - Show service status"
echo "   docker-service-logs    - View container logs"
echo "   docker-service-update  - Update to latest image"
echo ""
echo " Systemd Commands:"
echo "   systemctl status docker-${SERVICE_NAME}"
echo "   systemctl restart docker-${SERVICE_NAME}"
echo "   systemctl stop docker-${SERVICE_NAME}"
echo ""
