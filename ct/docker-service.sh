#!/usr/bin/env bash

# Docker-to-LXC: Deploy Docker Images as LXC Services
# Inspired by Proxmox VE Community Helper Scripts
# https://github.com/community-scripts/ProxmoxVE
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/ct/docker-service.sh)"
#
# Or with Docker image:
#   DOCKER_IMAGE="nginx:latest" bash docker-service.sh
#
# Copyright (c) 2024
# License: MIT

set -Eeuo pipefail

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

APP="Docker-Service"
APP_TAGS="docker;docker-service;container"

# Default container resources
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# =============================================================================
# INITIALIZATION
# =============================================================================

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source build framework
if [[ -f "${SCRIPT_DIR}/../misc/build.func" ]]; then
    source "${SCRIPT_DIR}/../misc/build.func"
else
    # Always download fresh framework when running from curl
    mkdir -p /tmp/docker-to-lxc/misc
    curl -fsSL "https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/misc/build.func?v=${RANDOM}" \
        -o /tmp/docker-to-lxc/misc/build.func
    source /tmp/docker-to-lxc/misc/build.func
fi

# =============================================================================
# UPDATE SCRIPT (runs inside container)
# =============================================================================

update_script() {
    header_info

    if [[ ! -f /etc/docker-service.conf ]]; then
        msg_error "No docker service configuration found"
        exit 1
    fi

    # Load service configuration
    source /etc/docker-service.conf

    local service_name="docker-${SERVICE_NAME}"

    msg_info "Checking for updates"

    # Update system packages
    apt-get update >/dev/null 2>&1
    apt-get upgrade -y >/dev/null 2>&1

    # Pull latest docker image
    msg_info "Pulling latest image: ${DOCKER_IMAGE}"
    docker pull "${DOCKER_IMAGE}" >/dev/null 2>&1

    # Restart service to use new image
    msg_info "Restarting service"
    systemctl restart "${service_name}"

    # Wait for service to be ready
    sleep 3

    if systemctl is-active --quiet "${service_name}"; then
        msg_ok "Service ${service_name} updated and running"
    else
        msg_error "Service failed to restart"
        systemctl status "${service_name}" --no-pager
        exit 1
    fi

    # Cleanup old images
    msg_info "Cleaning up old images"
    docker image prune -af >/dev/null 2>&1
    msg_ok "Cleanup complete"

    echo ""
    msg_ok "Update completed successfully!"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

# Start installation/update
start

# Get install script path
INSTALL_SCRIPT="${SCRIPT_DIR}/../install/docker-service-install.sh"

if [[ -f "$INSTALL_SCRIPT" ]]; then
    # Run local install script
    run_install_script_local "$INSTALL_SCRIPT"
else
    # Download and run install script
    run_install_script "https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/install/docker-service-install.sh"
fi

# Show completion message
description
