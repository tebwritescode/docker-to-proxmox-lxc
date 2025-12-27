#!/usr/bin/env bash

# OCI-to-LXC: Deploy OCI/Docker images as native LXC containers
# No Docker daemon required - minimal resource usage
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/ct/oci-to-lxc.sh)"
#
# Or with image specified:
#   OCI_IMAGE="fosrl/newt:latest" bash oci-to-lxc.sh
#
# Copyright (c) 2024
# License: MIT

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_VERSION="1.0.5"
OCI_IMAGE="${OCI_IMAGE:-}"
CT_NAME="${CT_NAME:-}"
CT_MEMORY="${CT_MEMORY:-256}"
CT_CORES="${CT_CORES:-1}"
CT_DISK="${CT_DISK:-1}"
CT_BRIDGE="${CT_BRIDGE:-}"
CT_STORAGE="${CT_STORAGE:-}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
NONINTERACTIVE="${NONINTERACTIVE:-}"
CONFIG_FILE="${CONFIG_FILE:-}"

# Config storage directory
CONFIG_DIR="/etc/oci-to-lxc"

# User-defined environment variables (populated during setup)
declare -A USER_ENV_VARS

# Auto-enable non-interactive if no TTY
[[ ! -t 0 ]] && NONINTERACTIVE=1

# Colors
RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;32m")
CL=$(echo "\033[m")
BL=$(echo "\033[36m")
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

msg_info() { echo -ne " ${INFO} ${YW}${1}...${CL}"; }
msg_ok() { echo -e "\r ${CM} ${GN}${1}${CL}"; }
msg_error() { echo -e "\r ${CROSS} ${RD}${1}${CL}"; }
msg() { echo -e " ${1}"; }

header_info() {
    clear
    cat <<"EOF"
   ____  ___________      __            __   _  ________
  / __ \/ ____/  _/     / /_____      / /  | |/ / ____/
 / / / / /    / /______/ __/ __ \    / /   |   / /
/ /_/ / /____/ /_____/ /_/ /_/ /   / /___/   / /___
\____/\____/___/     \__/\____/   /_____/_/|_\____/

EOF
    echo -e "${BL}OCI Image to Native LXC (No Docker)${CL}"
    echo -e "${YW}Version: ${SCRIPT_VERSION}${CL}\n"
}

cleanup() {
    [[ -d "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_error "This script must be run as root"
        exit 1
    fi
}

check_pve() {
    if ! command -v pveversion &>/dev/null; then
        msg_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    PVEVERSION=$(pveversion --verbose | grep pve-manager | awk '{print $2}' | cut -d'/' -f1)
    msg_ok "Proxmox VE ${PVEVERSION} detected"
}

check_deps() {
    local missing=()
    command -v skopeo &>/dev/null || missing+=("skopeo")
    command -v umoci &>/dev/null || missing+=("umoci")
    command -v jq &>/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_info "Installing dependencies: ${missing[*]}"
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1
        msg_ok "Dependencies installed"
    fi
}

# =============================================================================
# CONFIG FILE FUNCTIONS
# =============================================================================

list_configs() {
    mkdir -p "$CONFIG_DIR"
    local configs
    configs=$(find "$CONFIG_DIR" -name "*.conf" -type f 2>/dev/null | sort)
    echo "$configs"
}

load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        msg_error "Config file not found: ${config_file}"
        return 1
    fi

    # Source the config file
    # shellcheck disable=SC1090
    source "$config_file"

    # Load environment variables from config
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^ENV_ ]]; then
            local env_name="${key#ENV_}"
            USER_ENV_VARS["$env_name"]="$value"
        fi
    done < "$config_file"

    msg_ok "Loaded config: $(basename "$config_file")"
}

save_config() {
    local config_name="$1"

    mkdir -p "$CONFIG_DIR"
    local config_file="${CONFIG_DIR}/${config_name}.conf"

    cat > "$config_file" << EOF
# OCI-to-LXC Configuration
# Generated: $(date)
# Image: ${OCI_IMAGE}

OCI_IMAGE="${OCI_IMAGE}"
CT_NAME="${CT_NAME}"
CT_MEMORY="${CT_MEMORY}"
CT_CORES="${CT_CORES}"
CT_DISK="${CT_DISK}"
CT_BRIDGE="${CT_BRIDGE}"
CT_STORAGE="${CT_STORAGE}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE}"
EOF

    # Save environment variables
    for key in "${!USER_ENV_VARS[@]}"; do
        echo "ENV_${key}=\"${USER_ENV_VARS[$key]}\"" >> "$config_file"
    done

    msg_ok "Config saved: ${config_file}"
}

select_config() {
    local configs
    configs=$(list_configs)

    if [[ -z "$configs" ]]; then
        return 1
    fi

    local options=()
    options+=("NEW" "Create new container" "ON")

    while IFS= read -r conf; do
        [[ -z "$conf" ]] && continue
        local name
        name=$(basename "$conf" .conf)
        local image
        image=$(grep "^OCI_IMAGE=" "$conf" 2>/dev/null | cut -d'"' -f2 | head -1)
        options+=("$name" "${image:-unknown}" "OFF")
    done <<< "$configs"

    local selected
    selected=$(whiptail --backtitle "OCI-to-LXC" \
        --title "Configuration" \
        --radiolist "Load existing config or create new?" 16 70 8 \
        "${options[@]}" 3>&1 1>&2 2>&3) || return 1

    if [[ "$selected" != "NEW" && -n "$selected" ]]; then
        load_config "${CONFIG_DIR}/${selected}.conf"
        return 0
    fi

    return 1
}

# =============================================================================
# ENVIRONMENT VARIABLE FUNCTIONS
# =============================================================================

prompt_env_vars() {
    if [[ -n "$NONINTERACTIVE" ]]; then
        # In non-interactive mode, use pre-set values only
        return 0
    fi

    # Show existing env vars from config if any
    if [[ ${#USER_ENV_VARS[@]} -gt 0 ]]; then
        msg "Environment variables from config:"
        for key in "${!USER_ENV_VARS[@]}"; do
            msg "  ${key}=${USER_ENV_VARS[$key]}"
        done
        echo ""
    fi

    # Ask if user wants to configure environment variables
    if ! whiptail --backtitle "OCI-to-LXC" \
        --title "Environment Variables" \
        --yesno "Configure environment variables for this container?\n\n(Many Docker images require configuration like API keys, endpoints, etc.)" 10 70; then
        return 0
    fi

    # Loop to add environment variables
    while true; do
        local env_input
        env_input=$(whiptail --backtitle "OCI-to-LXC" \
            --title "Add Environment Variable" \
            --inputbox "Enter environment variable (NAME=value format):\n\nExamples:\n  PANGOLIN_ENDPOINT=https://example.com\n  API_KEY=your-key-here\n\nLeave empty when done adding variables." \
            14 70 "" 3>&1 1>&2 2>&3) || break

        # Empty input means done
        [[ -z "$env_input" ]] && break

        # Validate format
        if [[ "$env_input" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local env_name="${BASH_REMATCH[1]}"
            local env_value="${BASH_REMATCH[2]}"
            USER_ENV_VARS["$env_name"]="$env_value"
            msg_ok "Added: ${env_name}=${env_value}"
        else
            whiptail --backtitle "OCI-to-LXC" \
                --title "Invalid Format" \
                --msgbox "Invalid format. Use NAME=value format.\n\nVariable names must start with a letter or underscore." 10 60
        fi
    done

    # Show summary
    if [[ ${#USER_ENV_VARS[@]} -gt 0 ]]; then
        echo ""
        msg "Configured environment variables:"
        for key in "${!USER_ENV_VARS[@]}"; do
            msg "  ${key}=${USER_ENV_VARS[$key]}"
        done
    fi
}

# =============================================================================
# SELECTION FUNCTIONS
# =============================================================================

select_bridge() {
    [[ -n "$CT_BRIDGE" ]] && { msg_ok "Using bridge: ${CT_BRIDGE}"; return; }

    msg_info "Detecting network bridges"
    local bridge_list
    bridge_list=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort)

    if [[ -z "$bridge_list" ]]; then
        msg_error "No network bridges found"
        exit 1
    fi

    local count
    count=$(echo "$bridge_list" | wc -l)

    if [[ $count -eq 1 ]] || [[ -n "$NONINTERACTIVE" ]]; then
        CT_BRIDGE=$(echo "$bridge_list" | head -1)
        msg_ok "Using bridge: ${CT_BRIDGE}"
    else
        local options=()
        while IFS= read -r bridge; do
            local bridge_ip
            bridge_ip=$(ip -4 addr show "$bridge" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
            options+=("$bridge" "${bridge_ip:-no IP}" "OFF")
        done <<< "$bridge_list"
        options[2]="ON"

        CT_BRIDGE=$(whiptail --backtitle "OCI-to-LXC" \
            --title "Network Bridge" \
            --radiolist "Select network bridge:" 16 60 8 \
            "${options[@]}" 3>&1 1>&2 2>&3) || exit 1
        msg_ok "Selected bridge: ${CT_BRIDGE}"
    fi
}

select_storage() {
    local content_type="$1"
    local var_name="$2"

    # Skip if already set
    [[ -n "${!var_name}" ]] && { msg_ok "Using ${content_type} storage: ${!var_name}"; return; }

    msg_info "Detecting ${content_type} storage"
    local storage_list
    storage_list=$(pvesm status -content "$content_type" 2>/dev/null | awk 'NR>1 {print $1}' | sort)

    if [[ -z "$storage_list" ]]; then
        msg_error "No storage available for ${content_type}"
        exit 1
    fi

    local count
    count=$(echo "$storage_list" | wc -l)

    if [[ $count -eq 1 ]] || [[ -n "$NONINTERACTIVE" ]]; then
        eval "$var_name=$(echo "$storage_list" | head -1)"
        msg_ok "Using ${content_type} storage: ${!var_name}"
    else
        local options=()
        while IFS= read -r storage; do
            local storage_info
            storage_info=$(pvesm status | grep "^${storage}" | awk '{print $2" "$3}')
            options+=("$storage" "$storage_info" "OFF")
        done <<< "$storage_list"
        options[2]="ON"

        local selected
        selected=$(whiptail --backtitle "OCI-to-LXC" \
            --title "Storage Selection (${content_type})" \
            --radiolist "Select storage:" 16 60 8 \
            "${options[@]}" 3>&1 1>&2 2>&3) || exit 1
        eval "$var_name=$selected"
        msg_ok "Selected ${content_type} storage: ${!var_name}"
    fi
}

# =============================================================================
# OCI FUNCTIONS
# =============================================================================

sanitize_name() {
    echo "$1" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//' | sed 's/:.*$//'
}

pull_oci_image() {
    local image="$1"

    msg_info "Pulling OCI image: ${image}"

    WORK_DIR=$(mktemp -d)

    if ! skopeo copy "docker://${image}" "oci:${WORK_DIR}/image:latest" >/dev/null 2>&1; then
        msg_error "Failed to pull image: ${image}"
        exit 1
    fi
    msg_ok "Image pulled"
}

unpack_oci_image() {
    msg_info "Unpacking OCI image"

    if ! umoci unpack --image "${WORK_DIR}/image:latest" "${WORK_DIR}/bundle" >/dev/null 2>&1; then
        msg_error "Failed to unpack image"
        exit 1
    fi
    msg_ok "Image unpacked"
}

get_oci_config() {
    # Extract entrypoint/cmd from OCI config
    local config_file="${WORK_DIR}/bundle/config.json"

    if [[ -f "$config_file" ]]; then
        OCI_CMD=$(jq -r '.process.args | join(" ")' "$config_file" 2>/dev/null || echo "")
        OCI_WORKDIR=$(jq -r '.process.cwd // "/"' "$config_file" 2>/dev/null || echo "/")
        OCI_PATH=$(jq -r '.process.env[]? | select(startswith("PATH="))' "$config_file" 2>/dev/null | head -1 || echo "")
        OCI_ENV=$(jq -r '.process.env[]? | select(startswith("PATH=") | not)' "$config_file" 2>/dev/null | head -20 || echo "")
    fi

    # Default PATH if not found
    [[ -z "$OCI_PATH" ]] && OCI_PATH="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    msg_ok "Extracted config: ${OCI_CMD:-/bin/sh}"
}

create_template() {
    local template_name="$1"

    msg_info "Creating LXC template"

    local rootfs="${WORK_DIR}/bundle/rootfs"
    local template_path="/var/lib/vz/template/cache/${template_name}.tar.gz"

    # Create startup wrapper script with proper PATH and environment
    {
        echo "#!/bin/sh"
        echo "export ${OCI_PATH}"

        # Add user-defined environment variables
        for key in "${!USER_ENV_VARS[@]}"; do
            echo "export ${key}=\"${USER_ENV_VARS[$key]}\""
        done

        echo "cd ${OCI_WORKDIR}"
        echo "exec ${OCI_CMD:-/bin/sh}"
    } > "${rootfs}/etc/oci-start.sh"
    chmod +x "${rootfs}/etc/oci-start.sh"

    # Create minimal inittab for running the OCI command
    cat > "${rootfs}/etc/inittab" << EOF
# Minimal inittab for OCI container
::sysinit:/bin/hostname -F /etc/hostname
::sysinit:/sbin/ifup -a 2>/dev/null || true

# Run the main application via wrapper
::respawn:/etc/oci-start.sh

# Shutdown handling
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/ifdown -a 2>/dev/null || true
EOF

    # Ensure basic directories exist
    mkdir -p "${rootfs}/etc/network"
    cat > "${rootfs}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # Create tarball
    tar -C "$rootfs" -czf "$template_path" . 2>/dev/null

    TEMPLATE_FILE="$template_path"
    msg_ok "Template created: ${template_name}.tar.gz"
}

# =============================================================================
# CONTAINER FUNCTIONS
# =============================================================================

create_container() {
    local ct_name="$1"

    CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

    msg_info "Creating LXC container ${ct_name} (ID: ${CTID})"

    local template_file
    template_file=$(basename "$TEMPLATE_FILE")

    if ! pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${template_file}" \
        --hostname "$ct_name" \
        --memory "$CT_MEMORY" \
        --cores "$CT_CORES" \
        --rootfs "${CT_STORAGE}:${CT_DISK}" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
        --unprivileged 1 \
        --features nesting=1 \
        --ostype alpine \
        2>&1; then
        msg_error "Failed to create container"
        exit 1
    fi

    msg_ok "Container created (ID: ${CTID})"
}

start_container() {
    msg_info "Starting container"

    if ! pct start "$CTID" 2>&1; then
        msg_error "Failed to start container"
        exit 1
    fi

    # Wait for container to be ready
    sleep 3

    if pct status "$CTID" | grep -q "running"; then
        msg_ok "Container started"
    else
        msg_error "Container failed to start"
        exit 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    header_info
    check_root
    check_pve
    check_deps

    # Check for config file or offer to load existing
    local config_loaded=0
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE" && config_loaded=1
    elif [[ -z "$NONINTERACTIVE" ]]; then
        select_config && config_loaded=1
    fi

    # Get OCI image
    if [[ -z "$OCI_IMAGE" ]]; then
        if [[ -n "$NONINTERACTIVE" ]]; then
            msg_error "OCI_IMAGE must be set in non-interactive mode"
            exit 1
        fi
        OCI_IMAGE=$(whiptail --backtitle "OCI-to-LXC" \
            --title "OCI Image" \
            --inputbox "Enter Docker/OCI image (e.g., nginx:alpine, fosrl/newt:latest):" \
            10 70 3>&1 1>&2 2>&3) || exit 1
    fi

    if [[ -z "$OCI_IMAGE" ]]; then
        msg_error "No image specified"
        exit 1
    fi

    # Set container name from image if not specified
    [[ -z "$CT_NAME" ]] && CT_NAME=$(sanitize_name "$OCI_IMAGE")

    echo ""
    msg "Configuration:"
    msg "  Image:    ${OCI_IMAGE}"
    msg "  Name:     ${CT_NAME}"
    msg "  Memory:   ${CT_MEMORY}MB"
    msg "  Cores:    ${CT_CORES}"
    msg "  Disk:     ${CT_DISK}GB"
    echo ""

    # Confirm (skip in non-interactive mode)
    if [[ -z "$NONINTERACTIVE" ]]; then
        if ! whiptail --backtitle "OCI-to-LXC" \
            --title "Confirm" \
            --yesno "Create LXC from this OCI image?" 10 60; then
            msg "Cancelled"
            exit 0
        fi
    fi

    # Select resources
    select_bridge
    select_storage "rootdir" "CT_STORAGE"
    select_storage "vztmpl" "TEMPLATE_STORAGE"

    # Pull and unpack image
    pull_oci_image "$OCI_IMAGE"
    unpack_oci_image
    get_oci_config

    # Prompt for environment variables
    prompt_env_vars

    # Create template and container
    create_template "$CT_NAME"
    create_container "$CT_NAME"
    start_container

    # Get IP
    sleep 2
    local ip
    ip=$(pct exec "$CTID" -- sh -c "ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+'" 2>/dev/null || echo "pending")

    echo ""
    msg_ok "Container created successfully!"
    echo ""
    msg "Container Details:"
    msg "  ID:      ${CTID}"
    msg "  Name:    ${CT_NAME}"
    msg "  IP:      ${ip}"
    msg "  Image:   ${OCI_IMAGE}"
    msg "  Command: ${OCI_CMD:-/bin/sh}"
    echo ""
    msg "Management:"
    msg "  pct enter ${CTID}    # Shell access"
    msg "  pct stop ${CTID}     # Stop container"
    msg "  pct start ${CTID}    # Start container"
    echo ""

    # Offer to save config (skip in non-interactive mode)
    if [[ -z "$NONINTERACTIVE" ]]; then
        if whiptail --backtitle "OCI-to-LXC" \
            --title "Save Configuration" \
            --yesno "Save this configuration for future use?" 8 50; then
            save_config "$CT_NAME"
        fi
    fi
}

main "$@"
