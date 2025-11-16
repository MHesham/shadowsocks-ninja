#!/bin/sh
# === ss-router-ssproxy-provision.sh =========================================
# One-shot entrypoint:
#  - Installs required dependencies (if missing)
#  - Applies SS + DNS + TPROXY config with backup & health checks

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo
echo "[*] ss-router-ssproxy-provision: starting overall provisioning..."

# Call deps installer (will opkg install only if packages are missing)
sh "$SCRIPT_DIR/ss-router-install-deps.sh"

# Call configuration script (backup, firewall, dnsmasq, ssproxy service, health checks)
sh "$SCRIPT_DIR/ss-router-ssproxy-config.sh"

echo
echo "[*] ss-router-ssproxy-provision: all steps completed."
