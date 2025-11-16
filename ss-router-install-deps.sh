#!/bin/sh
# === ss-router-ssproxy-install-deps.sh ======================================
# Install required packages for Shadowsocks + TPROXY on a clean GL/OpenWrt.
#
# - Always runs 'opkg update' once at the beginning.
# - Only runs 'opkg install' for packages that are NOT yet installed.
# - Does NOT touch firewall or DNS or any config.

set -eu

say()  { printf "\n[*] %s\n" "$*"; }
ok()   { printf "    ✓ %s\n" "$*"; }
warn() { printf "    ! %s\n" "$*"; }

# --- sanity checks -----------------------------------------------------------

# Must be root
if [ "$(id -u 2>/dev/null || echo 0)" -ne 0 ]; then
  warn "This script must be run as root (opkg requires root)."
  exit 1
fi

# opkg must exist
if ! command -v opkg >/dev/null 2>&1; then
  warn "'opkg' command not found. Are you sure this is OpenWrt/GL-iNet firmware?"
  exit 1
fi

# --- always refresh package lists -------------------------------------------

say "Updating package lists (opkg update)..."

set +e
opkg update
rc_update=$?
set -e

if [ "$rc_update" -ne 0 ]; then
  warn "'opkg update' failed with exit code $rc_update. Check your WAN/Internet connectivity."
  exit 1
fi

say "Checking for required packages (install only if missing)..."

# Core Shadowsocks runtime + kernel deps + LuCI app + theme
REQUIRED_PKGS="shadowsocks-libev-ss-redir
shadowsocks-libev-ss-tunnel
shadowsocks-libev-config
ip-full
iptables-mod-tproxy
kmod-nf-tproxy
kmod-nf-conntrack
luci-app-shadowsocks-libev"

missing=""

# Detect missing packages using 'opkg status' (not 'list-installed', whose exit
# code is useless when no package matches).
for pkg in $REQUIRED_PKGS; do
  if opkg status "$pkg" 2>/dev/null | grep -q "Status: install"; then
    : # installed
  else
    missing="$missing $pkg"
  fi
done

if [ -n "$missing" ]; then
  warn "Missing packages detected:"
  for pkg in $missing; do
    printf "      - %s\n" "$pkg"
  done

  say "Installing missing packages..."

  # shellcheck disable=SC2086
  set +e
  opkg install $missing
  rc_install=$?
  set -e

  if [ "$rc_install" -ne 0 ]; then
    warn "'opkg install' reported an error (exit code $rc_install)."
  else
    ok "Installed missing packages: $missing"
  fi
else
  ok "All required packages already installed; no opkg install needed."
fi

# --- post-install verification -----------------------------------------------

post_missing=""
for pkg in $REQUIRED_PKGS; do
  if opkg status "$pkg" 2>/dev/null | grep -q "Status: install"; then
    : # ok
  else
    post_missing="$post_missing $pkg"
  fi
done

if [ -n "$post_missing" ]; then
  warn "Some required packages are still NOT installed:"
  for pkg in $post_missing; do
    printf "      - %s\n" "$pkg"
  done
  warn "Please check 'opkg install' output above and resolve manually."
  exit 1
fi

ok "All required packages are present."
ok "Dependency stage complete."