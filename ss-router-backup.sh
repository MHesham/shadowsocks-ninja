#!/bin/sh
# Shadowsocks + DNS + Firewall backup for GL.iNet/OpenWrt
# Usage: /root/ss-router-backup.sh [retention_count]
# Default retention: 5 archives
# Creates:
#   /root/ss-backups/ss-backup-LKG-YYYYmmdd-HHMMSS.tar.gz
#   /root/ss-backups/ss-backup-LKG-latest.tar.gz (symlink)
#   /root/ss-backups/LAST_DOWNLOAD_HINT.txt

set -u  # no `set -e` (avoid aborting on harmless non-zero statuses)

RETENTION="${1:-5}"
TS="$(date +%Y%m%d-%H%M%S)"
ROOT_OUT="/root/ss-backups"
mkdir -p "$ROOT_OUT" 2>/dev/null || true

# -------- Robust LAN IP detection (never empty) --------
detect_lan_ip() {
  # 1) Standard OpenWrt/GL key
  IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
  [ -n "${IP:-}" ] && { printf "%s" "$IP"; return; }

  # 2) Alternate key seen on some 23.x builds
  IP="$(uci -q get network.lan.ip4addr 2>/dev/null || true)"
  [ -n "${IP:-}" ] && { printf "%s" "$IP"; return; }

  # 3) Parse interface directly
  IP="$(ip -br addr show br-lan 2>/dev/null | awk '{print $3}' | cut -d/ -f1 \
        | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
  [ -n "${IP:-}" ] && { printf "%s" "$IP"; return; }

  # 4) Fallback to GL default
  printf "%s" "192.168.8.1"
}
LAN_IP="$(detect_lan_ip)"

# BusyBox-friendly mktemp, with fallback
SNAP_DIR="$(mktemp -d -p "$ROOT_OUT" "snap-$TS-XXXXXX" 2>/dev/null || echo "$ROOT_OUT/snap-$TS")"
[ -d "$SNAP_DIR" ] || mkdir -p "$SNAP_DIR"
ARCHIVE="$ROOT_OUT/ss-backup-LKG-$TS.tar.gz"

printf "[*] Snapshot dir: %s\n" "$SNAP_DIR"

# -------- helper: resolve actual archive that exists --------
resolve_actual_archive() {
  CAND="$1"
  if [ -s "$CAND" ]; then
    printf "%s" "$CAND"; return
  fi
  NEWEST="$(ls -1t "$ROOT_OUT"/ss-backup-LKG-*.tar.gz 2>/dev/null | head -n1)"
  if [ -n "$NEWEST" ] && [ -s "$NEWEST" ]; then
    printf "%s" "$NEWEST"; return
  fi
  printf "%s" ""
}

# -------- Always print & write hints on exit --------
print_hints() {
  ACTUAL="$(resolve_actual_archive "$ARCHIVE")"
  printf "\n[*] Download from your Mac with either:\n"
  if [ -n "$ACTUAL" ]; then
    printf "    ssh root@%s \"cat %s\" > %s\n" "$LAN_IP" "$ACTUAL" "$(basename "$ACTUAL")"
    printf "    # or, if your scp supports -O:\n"
    printf "    scp -O root@%s:%s .\n\n" "$LAN_IP" "$ACTUAL"
  else
    printf "    (No tarball found in %s — re-run the backup and retry.)\n\n" "$ROOT_OUT"
  fi
}
write_hints_file() {
  ACTUAL="$(resolve_actual_archive "$ARCHIVE")"
  HINTS="$ROOT_OUT/LAST_DOWNLOAD_HINT.txt"
  {
    printf "[%s]\n" "$TS"
    printf "LAN_IP=%s\nARCHIVE_REQUESTED=%s\nARCHIVE_ACTUAL=%s\n\n" "$LAN_IP" "$ARCHIVE" "${ACTUAL:-<none>}"
    if [ -n "$ACTUAL" ]; then
      printf "ssh root@%s \"cat %s\" > %s\n" "$LAN_IP" "$ACTUAL" "$(basename "$ACTUAL")"
      printf "scp -O root@%s:%s .\n" "$LAN_IP" "$ACTUAL"
    else
      printf "(No tarball found in %s — re-run the backup.)\n" "$ROOT_OUT"
    fi
  } >"$HINTS" 2>/dev/null || true
}
trap 'write_hints_file; print_hints' EXIT

# -------- Copy live configs --------
printf "[*] Copying UCI config files…\n"
for f in dhcp firewall network system ssproxy; do
  [ -f "/etc/config/$f" ] && cp -a "/etc/config/$f" "$SNAP_DIR/" 2>/dev/null || true
done

printf "[*] Copying init scripts and custom hooks…\n"
for p in /etc/init.d/shadowsocks-libev /etc/init.d/ssproxy /etc/firewall.user /etc/rc.local; do
  [ -e "$p" ] && cp -a "$p" "$SNAP_DIR/" 2>/dev/null || true
done

printf "[*] Copying dnsmasq extras…\n"
[ -f /etc/dnsmasq.conf ] && cp -a /etc/dnsmasq.conf "$SNAP_DIR/" 2>/dev/null || true
[ -d /etc/dnsmasq.d ]   && cp -a /etc/dnsmasq.d "$SNAP_DIR/"     2>/dev/null || true

printf "[*] Copying Shadowsocks configs…\n"
if [ -d /etc/shadowsocks-libev ]; then
  DST="$SNAP_DIR/etc-shadowsocks-libev"
  rm -rf "$DST" 2>/dev/null || true
  mkdir -p "$DST" 2>/dev/null || true
  cp -a /etc/shadowsocks-libev/. "$DST/" 2>/dev/null || true
fi

printf "[*] Copying sysctl and limits…\n"
[ -f /etc/sysctl.conf ]          && cp -a /etc/sysctl.conf "$SNAP_DIR/" 2>/dev/null || true
[ -f /etc/security/limits.conf ] && cp -a /etc/security/limits.conf "$SNAP_DIR/" 2>/dev/null || true

printf "[*] Copying GL.iNet helper configs (if present)…\n"
for p in /etc/init.d/gl_*; do
  [ -e "$p" ] && cp -a "$p" "$SNAP_DIR/" 2>/dev/null || true
done

# -------- UCI exports (diff-friendly) --------
printf "[*] Exporting UCI (forensics)…\n"
mkdir -p "$SNAP_DIR/uci" 2>/dev/null || true
for c in dhcp firewall network system; do
  uci export "$c" > "$SNAP_DIR/uci/$c.export" 2>/dev/null || true
done

# -------- Diagnostics (iptables/nft, routes, rules) --------
printf "[*] Saving diagnostics…\n"
{ echo "# iptables-save"; iptables-save 2>/dev/null || true; }   > "$SNAP_DIR/iptables-save.txt"
{ echo "# ip6tables-save"; ip6tables-save 2>/dev/null || true; } > "$SNAP_DIR/ip6tables-save.txt"
{ echo "# nft list ruleset"; nft list ruleset 2>/dev/null || true; } > "$SNAP_DIR/nft-ruleset.txt"

ip rule show                 > "$SNAP_DIR/ip-rule.txt"          2>/dev/null || true
ip route show table main     > "$SNAP_DIR/ip-route-main.txt"    2>/dev/null || true
ip route show table 100      > "$SNAP_DIR/ip-route-100.txt"     2>/dev/null || true
ip -br addr show             > "$SNAP_DIR/ip-addr.txt"          2>/dev/null || true

pgrep -a ss-redir   > "$SNAP_DIR/pgrep-ss-redir.txt"   2>/dev/null || true
pgrep -a ss-tunnel  > "$SNAP_DIR/pgrep-ss-tunnel.txt"  2>/dev/null || true
if command -v ubus >/dev/null 2>&1; then
  ubus call service list '{"name":"ssproxy"}' > "$SNAP_DIR/ubus-ssproxy.json" 2>/dev/null || true
fi

# -------- Create the archive (robust) --------
printf "[*] Creating archive: %s\n" "$ARCHIVE"
if [ -d "$SNAP_DIR" ]; then
  tar -C "$SNAP_DIR" -czf "$ARCHIVE" . 2>/tmp/backup-tar.err
  if [ -s "$ARCHIVE" ]; then
    printf "    [OK] Archive created, size: %s bytes\n" "$(stat -c%s "$ARCHIVE" 2>/dev/null)"
  else
    printf "    [WARN] tar produced no output — see /tmp/backup-tar.err\n"
  fi
else
  printf "    [ERR] Snapshot dir missing: %s\n" "$SNAP_DIR"
fi

# SHA256 (if available)
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$ROOT_OUT" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" ) 2>/dev/null || true
fi

# Update "latest" symlink
ln -sfn "$ARCHIVE" "$ROOT_OUT/ss-backup-LKG-latest.tar.gz" 2>/dev/null || true

printf "[*] Archive ready (if created):\n"
printf "    %s\n" "$ARCHIVE"
[ -s "$ARCHIVE.sha256" ] && printf "    %s\n" "$ARCHIVE.sha256"

# -------- Retention: keep N most recent --------
printf "[*] Applying retention: keep last %s backups\n" "$RETENTION"
i=0
for f in $(ls -1t "$ROOT_OUT"/ss-backup-LKG-*.tar.gz 2>/dev/null || true); do
  i=$((i+1))
  if [ "$i" -gt "$RETENTION" ]; then
    rm -f "$f" "$f.sha256" 2>/dev/null || true
  fi
done
