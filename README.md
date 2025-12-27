# 🐳 Docker-to-Proxmox-LXC

> Deploy Docker/OCI images as native Proxmox LXC containers with minimal resource usage - no Docker daemon required.

![Version](https://img.shields.io/badge/Version-1.0.0-brightgreen)
![Proxmox](https://img.shields.io/badge/Proxmox-7.0%2B-orange)
![Shell](https://img.shields.io/badge/Shell-Bash-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

---

## Screenshots

<details>
  <summary><i>Click to show screenshots</i></summary>

*Screenshots coming soon*

</details>

## 🆕 What's New in v1.0.0

### 🚀 Initial Release
- **OCI-to-LXC**: Convert Docker images directly to native LXC (no Docker daemon)
- **Docker-in-LXC**: Full Docker compatibility mode for complex images
- **Auto-detection**: Bridges, storage, and templates automatically detected
- **Interactive mode**: Whiptail-based menus for easy configuration

## ✨ Features

### 🪶 **OCI-to-LXC (Lightweight)**
- Convert any Docker/OCI image to native LXC
- No Docker daemon required - saves ~150MB+ RAM
- Uses `skopeo` and `umoci` for image handling
- Automatic entrypoint/CMD extraction
- Minimal footprint (~30MB for typical Go apps)

### 🐋 **Docker-in-LXC (Full Compatibility)**
- Run Docker inside LXC for complex images
- Full `docker-compose` support
- Systemd service integration
- Auto-restart on failure

### 🔧 **Smart Detection**
- Auto-detect available network bridges
- Auto-select storage for rootfs and templates
- Template caching for faster deployments

### 📦 **Configuration Options**
- Interactive whiptail menus
- Environment variable configuration
- Config file support for automation

## 🚀 Quick Start

### Prerequisites
- Proxmox VE 7.0+
- Root access on Proxmox host

### Installation Options

#### **Option 1: OCI-to-LXC** (Recommended - Lightweight)

```bash
# Interactive mode
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/ct/oci-to-lxc.sh)"

# With image pre-specified
OCI_IMAGE="nginx:alpine" bash -c "$(curl -fsSL https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/ct/oci-to-lxc.sh)"
```

#### **Option 2: Docker-in-LXC** (Full Compatibility)

```bash
# Interactive mode
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/ct/docker-service.sh)"

# With image pre-specified
DOCKER_IMAGE="nginx:latest" bash -c "$(curl -fsSL https://raw.githubusercontent.com/tebwritescode/docker-to-proxmox-lxc/main/ct/docker-service.sh)"
```

## 🔧 Configuration

### OCI-to-LXC Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OCI_IMAGE` | - | Docker/OCI image to deploy (required) |
| `CT_NAME` | *from image* | Container hostname |
| `CT_MEMORY` | `256` | Memory in MB |
| `CT_CORES` | `1` | CPU cores |
| `CT_DISK` | `1` | Disk size in GB |

### Docker-in-LXC Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOCKER_IMAGE` | - | Docker image to deploy (required) |
| `DOCKER_PORTS` | - | Port mappings (e.g., `80:80,443:443`) |
| `DOCKER_VOLUMES` | - | Volume mounts (e.g., `/data:/app/data`) |
| `DOCKER_ENV` | - | Environment variables |
| `var_cpu` | `2` | CPU cores |
| `var_ram` | `2048` | Memory in MB |
| `var_disk` | `8` | Disk size in GB |

## 📖 Usage Guide

### **OCI-to-LXC**
1. Run the script on your Proxmox host
2. Enter the Docker image name (e.g., `fosrl/newt:latest`)
3. Select network bridge and storage
4. Container is created and started automatically

### **Docker-in-LXC**
1. Run the script on your Proxmox host
2. Choose default or advanced settings
3. Enter Docker image and optional port/volume mappings
4. Container is created with systemd service for the Docker container

### **Management Commands**

```bash
# Shell access
pct enter <CTID>

# Start/stop container
pct start <CTID>
pct stop <CTID>

# View logs (Docker-in-LXC only)
pct exec <CTID> -- docker logs <container-name>
```

## 🏗️ Architecture

```
docker-to-proxmox-lxc/
├── 📁 ct/
│   ├── 📄 oci-to-lxc.sh          # OCI to native LXC (lightweight)
│   └── 📄 docker-service.sh      # Docker-in-LXC (full compat)
├── 📁 install/
│   └── 📄 docker-service-install.sh  # Docker installation script
├── 📁 misc/
│   └── 📄 build.func             # Shared build framework
├── 📁 configs/
│   ├── 📄 default.conf           # Default configuration
│   └── 📁 examples/              # Example configurations
├── 📄 LICENSE
└── 📄 README.md
```

### Resource Comparison

| Method | RAM Usage | Disk | Docker Daemon |
|--------|-----------|------|---------------|
| OCI-to-LXC | ~30MB | 1GB | ❌ None |
| Docker-in-LXC | ~200MB+ | 8GB+ | ✅ Running |

## 🔐 Security

- Unprivileged containers by default
- Nesting enabled only when required
- No host modifications (only creates LXCs)

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

Inspired by [Proxmox VE Community Helper Scripts](https://github.com/community-scripts/ProxmoxVE)
