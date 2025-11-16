#!/bin/bash
#
# ss-router-deploy.sh
# Upload all Shadowsocks router scripts to the GL router in one step.
#
# Usage:
#   ./ss-router-deploy.sh
#
# Requirements:
#   - Run this on your Mac
#   - All router scripts must be in the same directory as this deploy script
#
# This script:
#   - Locates all ss-router scripts
#   - Uses "scp -O" for reliable copying to GL routers
#   - Uploads everything to /root/ on the router
#   - chmod +x all uploaded scripts automatically

ROUTER_IP="192.168.8.1"
ROUTER_USER="root"
TARGET_DIR="/root"

echo "=============================================="
echo " Shadowsocks Router – Deployment Tool"
echo "=============================================="
echo "Router IP:   $ROUTER_IP"
echo "Destination: $TARGET_DIR"
echo ""

# ---------------------------------------------------------------------------
# 1. Collect scripts
# ---------------------------------------------------------------------------
echo "[1/3] Scanning for router scripts…"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

SCRIPTS=$(ls ss-router-*.sh 2>/dev/null)

if [ -z "$SCRIPTS" ]; then
    echo "ERROR: No ss-router-*.sh scripts found in:"
    echo "  $SCRIPT_DIR"
    exit 1
fi

echo "Found scripts:"
echo "$SCRIPTS"
echo ""

# ---------------------------------------------------------------------------
# 2. Upload using scp -O
# ---------------------------------------------------------------------------
echo "[2/3] Uploading scripts to router using: scp -O"
echo ""

scp -O $SCRIPTS ${ROUTER_USER}@${ROUTER_IP}:${TARGET_DIR}/
if [ $? -ne 0 ]; then
    echo ""
    echo "ERROR: SCP upload failed."
    echo "Make sure:"
    echo "  - Router is reachable"
    echo "  - SSH is enabled"
    echo "  - Password is correct"
    exit 1
fi

echo ""
echo "[OK] Scripts uploaded successfully."

# ---------------------------------------------------------------------------
# 3. SSH to apply chmod
# ---------------------------------------------------------------------------
echo ""
echo "[3/3] Setting execute permissions on router…"

ssh ${ROUTER_USER}@${ROUTER_IP} "chmod +x ${TARGET_DIR}/ss-router-*.sh"

if [ $? -ne 0 ]; then
    echo "WARNING: Could not chmod scripts on router."
    echo "You may need to do it manually."
else
    echo "[OK] Permissions updated."
fi

echo ""
echo "=============================================="
echo " Deployment complete!"
echo " You can now log in and run:"
echo "   ssh root@${ROUTER_IP}"
echo "   ./ss-router-provision-v3.2-dota.sh"
echo "=============================================="