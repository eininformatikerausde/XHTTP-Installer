#!/usr/bin/env bash
# XHTTP Installer - Bootstrap
# by avaco_cloud

set -euo pipefail

REPO_URL="https://github.com/avacocloud/XHTTP-Installer.git"
INSTALL_DIR="/root/XHTTP-Installer"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║         XHTTP Installer Bootstrapper     ║"
echo "║         by avaco_cloud                   ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] This script must be run as root.${NC}"
  exit 1
fi

# Install git if missing
if ! command -v git &>/dev/null; then
  echo "[*] Installing git..."
  apt-get update -qq && apt-get install -y git -qq
fi

# Clone or update repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "[*] Updating existing repo..."
  git -C "$INSTALL_DIR" pull --quiet
else
  echo "[*] Cloning XHTTP-Installer..."
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi

echo -e "${GREEN}[✔] Repository ready at $INSTALL_DIR${NC}"

chmod +x "$INSTALL_DIR/Deploy-Ubuntu.sh"
bash "$INSTALL_DIR/Deploy-Ubuntu.sh"
