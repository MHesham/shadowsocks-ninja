#!/bin/sh
# Shadowsocks/OpenWrt restore script
# Usage:
#   /root/ss-router-restore.sh /path/to/backup.tar.gz [--apply]
#   (omit --apply to preview only / dry-run)

set -eu

BACKUP_FILE="${1:-}"
APPLY="${2:-}"

if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "[!] Usage: $0 /path/to/ss-backup-LKG-*.tar.gz [--apply]"
  echo "    e.g.  /root/ss-router-restore.sh /root/ss-backups/ss-backup-LKG-latest.tar.gz"
  exit 1
fi

WORK_DIR="/tmp/restore-$RANDOM"
mkdir -p "$WORK_DIR"

echo "[*] Extracting archive: $BACKUP_FILE → $WORK_DIR"
tar -xzf "$BACKUP_FILE" -C "$WORK_DIR"

echo "[*] Contents:"
ls -R "$WORK_DIR" | sed 's/^/   /'

# Important safety checks
echo
echo "[*] Verifying structure..."
for dir in etc etc-shadowsocks-libev; do
  if [ -d "$WORK_DIR/$dir" ]; then
    echo "   ✓ Found $dir"
  fi
done

echo
if [ "$APPLY" != "--apply" ]; then
  echo "[DRY-RUN] Not applying changes yet."
  echo "          To actually restore, re-run with --apply."
  echo "          Example:"
  echo "             /root/ss-router-restore.sh $BACKUP_FILE --apply"
  exit 0
fi

echo
echo "[!] Applying restore — overwriting current configs!"
sleep 2

# Restore main UCI configs
for f in dhcp firewall network system ssproxy; do
  if [ -f "$WORK_DIR/$f" ]; then
    echo "   -> /etc/config/$f"
    cp -a "$WORK_DIR/$f" /etc/config/
  fi
done

# Restore init scripts and firewall.user
for p in /etc/init.d/shadowsocks-libev /etc/init.d/ssproxy /etc/firewall.user /etc/rc.local; do
  BASE="$(basename "$p")"
  if [ -f "$WORK_DIR/$BASE" ]; then
    echo "   -> $p"
    cp -a "$WORK_DIR/$BASE" "$p"
    chmod +x "$p" 2>/dev/null || true
  fi
done

# Restore dnsmasq and shadowsocks-libev dirs
if [ -f "$WORK_DIR/dnsmasq.conf" ]; then
  echo "   -> /etc/dnsmasq.conf"
  cp -a "$WORK_DIR/dnsmasq.conf" /etc/dnsmasq.conf
fi
if [ -d "$WORK_DIR/dnsmasq.d" ]; then
  echo "   -> /etc/dnsmasq.d/"
  mkdir -p /etc/dnsmasq.d
  cp -a "$WORK_DIR/dnsmasq.d/." /etc/dnsmasq.d/
fi
if [ -d "$WORK_DIR/etc-shadowsocks-libev" ]; then
  echo "   -> /etc/shadowsocks-libev/"
  mkdir -p /etc/shadowsocks-libev
  cp -a "$WORK_DIR/etc-shadowsocks-libev/." /etc/shadowsocks-libev/
fi

# Restore sysctl and limits
for f in sysctl.conf limits.conf; do
  if [ -f "$WORK_DIR/$f" ]; then
    echo "   -> /etc/$f"
    cp -a "$WORK_DIR/$f" /etc/
  fi
done

# Sync changes
echo "[*] Committing and restarting services..."
uci commit dhcp 2>/dev/null || true
uci commit firewall 2>/dev/null || true
uci commit network 2>/dev/null || true

/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall restart 2>/dev/null || true
/etc/init.d/network reload 2>/dev/null || true
/etc/init.d/shadowsocks-libev restart 2>/dev/null || true

echo "[✓] Restore complete. Review settings and reboot if needed."
