#!/bin/sh
# === ss-router-ssproxy-config.sh ============================================
# Configure Shadowsocks full-tunnel (ss-redir + ss-tunnel + TPROXY)
# with:
#   - Backup & rollback of firewall/dhcp/firewall.user/dnsmasq snippet
#   - Custom /etc/init.d/ssproxy service
#   - dnsmasq -> ss-tunnel DNS
#   - STRICT health checks and auto-rollback on failure
#
# Assumes packages are already installed by the deps script.

set -eu

# ---- 0) SETTINGS ------------------------------------------------------------
: "${SS_HOST:=3.80.130.31}"
: "${SS_PORT:=8389}"
: "${SS_PASS:=rHg8MtMtyTF}"

: "${SS_METHOD:=chacha20-ietf-poly1305}"
: "${REDIR_PORT:=1081}"
: "${TUNNEL_PORT:=8054}"
: "${UPSTREAM_DNS:=1.1.1.1:53}"
: "${WORKERS:=2}"
: "${BLOCK_QUIC:=1}"

# IP to use for TPROXY test (must be routable internet IP)
TPROXY_TEST_IP="1.1.1.1"

say()  { printf "\n[*] %s\n" "$*"; }
ok()   { printf "    ✓ %s\n" "$*"; }
warn() { printf "    ! %s\n" "$*"; }

BACKUP_DIR=""
RESTORE_NEEDED=0

# ---- HELPERS ----------------------------------------------------------------

tcp_listening() {
  port="$1"
  port_hex=$(printf "%04X" "$port")
  if grep -q ":$port_hex " /proc/net/tcp 2>/dev/null; then
    return 0
  fi
  if grep -q ":$port_hex " /proc/net/tcp6 2>/dev/null; then
    return 0
  fi
  return 1
}

udp_listening() {
  port="$1"
  port_hex=$(printf "%04X" "$port")
  if grep -q ":$port_hex " /proc/net/udp 2>/dev/null; then
    return 0
  fi
  if grep -q ":$port_hex " /proc/net/udp6 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---- A) BACKUP & RESTORE ---------------------------------------------------

backup_configs() {
  set +e
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  BACKUP_DIR="/root/ss-router-backup-${ts}"
  mkdir -p "$BACKUP_DIR"

  uci export firewall >"$BACKUP_DIR/firewall.ucibak" 2>/dev/null
  uci export dhcp >"$BACKUP_DIR/dhcp.ucibak" 2>/dev/null

  cp /etc/firewall.user "$BACKUP_DIR/firewall.user.bak" 2>/dev/null
  cp /etc/dnsmasq.d/shadowsocks.conf "$BACKUP_DIR/shadowsocks.conf.bak" 2>/dev/null || true

  set -e
  ok "Configs backed up to $BACKUP_DIR"
}

restore_configs() {
  warn "Restoring previous configuration from backup..."

  set +e

  if [ -f "$BACKUP_DIR/firewall.ucibak" ]; then
    uci import firewall <"$BACKUP_DIR/firewall.ucibak"
    uci commit firewall
  fi

  if [ -f "$BACKUP_DIR/dhcp.ucibak" ]; then
    uci import dhcp <"$BACKUP_DIR/dhcp.ucibak"
    uci commit dhcp
  fi

  if [ -f "$BACKUP_DIR/firewall.user.bak" ]; then
    cp "$BACKUP_DIR/firewall.user.bak" /etc/firewall.user
  else
    rm -f /etc/firewall.user
  fi

  if [ -f "$BACKUP_DIR/shadowsocks.conf.bak" ]; then
    cp "$BACKUP_DIR/shadowsocks.conf.bak" /etc/dnsmasq.d/shadowsocks.conf
  else
    rm -f /etc/dnsmasq.d/shadowsocks.conf
  fi

  /etc/init.d/firewall restart 2>/dev/null
  /etc/init.d/dnsmasq restart 2>/dev/null

  set -e
  warn "Previous config RESTORED. SSH over LAN should behave as before."
}

on_exit() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$RESTORE_NEEDED" -eq 1 ]; then
    restore_configs || true
    warn "Provisioning FAILED (exit $status). Backup restored."
  fi
}
trap on_exit EXIT

# ---- B) APPLY IP RULES + IPTABLES RULES ------------------------------------

apply_tproxy_rules() {
  say "Applying TPROXY routing + iptables rules (in addition to firewall.user)..."

  ip rule add fwmark 1 lookup 100 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table 100 2>/dev/null || \
  ip route replace local default dev lo table 100 2>/dev/null || true

  iptables -t nat -N SHADOWSOCKS 2>/dev/null || true
  iptables -t nat -F SHADOWSOCKS 2>/dev/null || true
  for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
             192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t nat -A SHADOWSOCKS -d "$net" -j RETURN
  done
  iptables -t nat -A SHADOWSOCKS -p tcp -j REDIRECT --to-ports "${REDIR_PORT}"
  iptables -t nat -C PREROUTING -i br-lan -p tcp -j SHADOWSOCKS 2>/dev/null || \
    iptables -t nat -A PREROUTING -i br-lan -p tcp -j SHADOWSOCKS

  iptables -t mangle -N SHADOWSOCKS 2>/dev/null || true
  iptables -t mangle -F SHADOWSOCKS 2>/dev/null || true
  for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
             192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t mangle -A SHADOWSOCKS -d "$net" -j RETURN
  done
  iptables -t mangle -A SHADOWSOCKS -p udp -j TPROXY \
    --on-port "${REDIR_PORT}" --tproxy-mark 0x01/0x01
  iptables -t mangle -C PREROUTING -i br-lan -p udp -j SHADOWSOCKS 2>/dev/null || \
    iptables -t mangle -A PREROUTING -i br-lan -p udp -j SHADOWSOCKS

  ok "TPROXY routing + iptables rules applied."
}

# ---- C) HEALTH CHECKS (STRICT ON WHAT MATTERS) -----------------------------

health_checks() {
  say "Performing post-config health checks (STRICT)..."
  okflag=1

  if tcp_listening "${REDIR_PORT}" && udp_listening "${REDIR_PORT}"; then
    ok "ss-redir listening on TCP/UDP ${REDIR_PORT}"
  else
    warn "ss-redir NOT listening correctly on ${REDIR_PORT} (TCP+UDP)"
    okflag=0
  fi

  if tcp_listening "${TUNNEL_PORT}" && udp_listening "${TUNNEL_PORT}"; then
    ok "ss-tunnel listening on TCP/UDP ${TUNNEL_PORT}"
  else
    warn "ss-tunnel NOT listening correctly on ${TUNNEL_PORT} (TCP+UDP)"
    okflag=0
  fi

  if ip rule show 2>/dev/null | grep -q "fwmark 0x1 lookup 100"; then
    ok "IP rule fwmark 0x1 -> table 100 present"
  else
    warn "Missing fwmark rule (0x1 -> table 100)"
    okflag=0
  fi

  route_test="$(ip route get "${TPROXY_TEST_IP}" mark 0x1 2>/dev/null || true)"
  if echo "$route_test" | grep -q "local ${TPROXY_TEST_IP} dev lo"; then
    ok "TPROXY route table 100 correctly routes marked traffic to local dev lo"
  else
    warn "TPROXY route test FAILED for ${TPROXY_TEST_IP} with mark 0x1:"
    printf '        %s\n' "$route_test"
    okflag=0
  fi

  if iptables -t nat -C PREROUTING -i br-lan -p tcp -j SHADOWSOCKS 2>/dev/null; then
    ok "NAT PREROUTING -> SHADOWSOCKS (TCP) OK"
  else
    warn "Missing NAT PREROUTING hook to SHADOWSOCKS"
    okflag=0
  fi

  if iptables -t mangle -C PREROUTING -i br-lan -p udp -j SHADOWSOCKS 2>/dev/null; then
    ok "Mangle PREROUTING -> SHADOWSOCKS (UDP) OK"
  else
    warn "Missing mangle PREROUTING hook to SHADOWSOCKS"
    okflag=0
  fi

  if command -v dig >/dev/null 2>&1; then
    dig_out="$(dig @127.0.0.1 -p ${TUNNEL_PORT} CH TXT whoami.cloudflare +short 2>&1 || true)"
    if echo "$dig_out" | grep -qiE 'communications error|no servers could be reached'; then
      warn "DNS tunnel FAILED (connection error to ss-tunnel):"
      printf '        %s\n' "$dig_out"
      okflag=0
    elif [ -n "$dig_out" ]; then
      ok "DNS tunnel OK (whoami.cloudflare: $dig_out)"
    else
      warn "DNS tunnel FAILED (empty whoami.cloudflare response)"
      okflag=0
    fi
  else
    warn "dig not installed; DNS tunnel cannot be verified strictly."
    okflag=0
  fi

  # HTTP egress: informational only (router may or may not be tunneled)
  if command -v curl >/dev/null 2>&1; then
    ip_out="$(curl -4 -s --max-time 8 https://api.ipify.org || true)"
    if [ -n "$ip_out" ]; then
      ok "HTTP egress reachable (api.ipify.org -> $ip_out, SS_HOST is $SS_HOST)"
    else
      warn "HTTP egress check FAILED (curl to api.ipify.org)"
      okflag=0
    fi
  else
    warn "curl not installed; HTTP egress cannot be checked."
  fi

  [ "$okflag" -eq 1 ]
}

# ---- 1) Backup current config ----------------------------------------------
backup_configs
RESTORE_NEEDED=1

# ---- 2) Install /etc/init.d/ssproxy service --------------------------------

say "Installing /etc/init.d/ssproxy service..."
cat >/etc/init.d/ssproxy <<'EOF'
#!/bin/sh /etc/rc.common
START=98
USE_PROCD=1

REDIR_BIN="/usr/bin/ss-redir"
TUNNEL_BIN="/usr/bin/ss-tunnel"

: "${SS_HOST:=3.80.130.31}"
: "${SS_PORT:=8389}"
: "${SS_PASS:=rHg8MtMtyTF}"

: "${SS_METHOD:=chacha20-ietf-poly1305}"
: "${REDIR_PORT:=1081}"
: "${TUNNEL_PORT:=8054}"
: "${UPSTREAM_DNS:=1.1.1.1:53}"
: "${WORKERS:=2}"

start_service() {
  [ -x "$REDIR_BIN" ] || exit 1
  [ -x "$TUNNEL_BIN" ] || exit 1

  i=1
  while [ "$i" -le "$WORKERS" ]; do
    procd_open_instance "redir$i"
    procd_set_param command "$REDIR_BIN" \
      -s "$SS_HOST" -p "$SS_PORT" -k "$SS_PASS" -m "$SS_METHOD" \
      -l "$REDIR_PORT" -u -b 0.0.0.0 --fast-open --reuse-port --no-delay
    procd_set_param respawn 5 2 0
    procd_close_instance
    i=$((i+1))
  done

  procd_open_instance dns
  procd_set_param command "$TUNNEL_BIN" \
    -s "$SS_HOST" -p "$SS_PORT" -k "$SS_PASS" -m "$SS_METHOD" \
    -l "$TUNNEL_PORT" -L "$UPSTREAM_DNS" -u -b 127.0.0.1 --fast-open --reuse-port
  procd_set_param respawn 5 2 0
  procd_close_instance
}

stop_service() { :; }
EOF

chmod +x /etc/init.d/ssproxy
/etc/init.d/ssproxy enable
ok "ssproxy service written and enabled."

# ---- 3) DNS: route router DNS via ss-tunnel --------------------------------

say "Configuring dnsmasq to forward DNS to 127.0.0.1:${TUNNEL_PORT}..."
mkdir -p /etc/dnsmasq.d
cat >/etc/dnsmasq.d/shadowsocks.conf <<EOF
no-resolv
server=127.0.0.1#${TUNNEL_PORT}
EOF

uci -q set dhcp.@dnsmasq[0].noresolv='1'
uci -q set dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
uci -q del dhcp.@dnsmasq[0].server 2>/dev/null || true
uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#${TUNNEL_PORT}"
uci commit dhcp
/etc/init.d/dnsmasq restart
ok "dnsmasq configured to use ss-tunnel."

# ---- 4) Optional: block QUIC (UDP/443) -------------------------------------

if [ "$BLOCK_QUIC" -eq 1 ]; then
  say "Adding firewall rule to DROP LAN->WAN UDP/443 (QUIC)..."
  uci -q delete firewall.ss_block_quic 2>/dev/null || true
  uci set firewall.ss_block_quic="rule"
  uci set firewall.ss_block_quic.name="Block-QUIC-UDP443"
  uci set firewall.ss_block_quic.src="lan"
  uci set firewall.ss_block_quic.dest="wan"
  uci set firewall.ss_block_quic.proto="udp"
  uci set firewall.ss_block_quic.dest_port="443"
  uci set firewall.ss_block_quic.target="DROP"
  uci commit firewall
  ok "QUIC block rule configured."
fi

# ---- 5) Disable flow offloading --------------------------------------------

say "Disabling flow_offloading (to avoid bypass via hardware offload)..."
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# ---- 6) Persist TPROXY + NAT redirect in /etc/firewall.user ----------------

say "Writing /etc/firewall.user with TPROXY + NAT redirect rules..."
cat >/etc/firewall.user <<EOF
# Shadowsocks persistent rules (written by ss-router-ssproxy-config.sh)
ip rule add fwmark 1 lookup 100 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

iptables -t nat -N SHADOWSOCKS 2>/dev/null || true
iptables -t nat -F SHADOWSOCKS 2>/dev/null || true
for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
  iptables -t nat -A SHADOWSOCKS -d \$net -j RETURN
done
iptables -t nat -A SHADOWSOCKS -p tcp -j REDIRECT --to-ports ${REDIR_PORT}
iptables -t nat -C PREROUTING -i br-lan -p tcp -j SHADOWSOCKS 2>/dev/null || \
  iptables -t nat -A PREROUTING -i br-lan -p tcp -j SHADOWSOCKS

iptables -t mangle -N SHADOWSOCKS 2>/dev/null || true
iptables -t mangle -F SHADOWSOCKS 2>/dev/null || true
for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
  iptables -t mangle -A SHADOWSOCKS -d \$net -j RETURN
done
iptables -t mangle -A SHADOWSOCKS -p udp -j TPROXY --on-port ${REDIR_PORT} --tproxy-mark 0x01/0x01
iptables -t mangle -C PREROUTING -i br-lan -p udp -j SHADOWSOCKS 2>/dev/null || \
  iptables -t mangle -A PREROUTING -i br-lan -p udp -j SHADOWSOCKS
EOF

/etc/init.d/firewall restart
ok "Firewall rules applied and firewall restarted."

apply_tproxy_rules

# ---- 7) Enable TCP Fast Open -----------------------------------------------

say "Enabling TCP Fast Open..."
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null || true
if ! grep -q '^net.ipv4.tcp_fastopen' /etc/sysctl.conf 2>/dev/null; then
  echo 'net.ipv4.tcp_fastopen=3' >> /etc/sysctl.conf
fi
ok "TCP Fast Open enabled (runtime + persisted)."

# ---- 8) Start ssproxy service ----------------------------------------------

say "Starting ssproxy (ss-redir workers + ss-tunnel)..."
/etc/init.d/ssproxy restart || true
sleep 1
ok "ssproxy restart requested."

# ---- 9) Health checks -------------------------------------------------------

if ! health_checks; then
  warn "One or more health checks FAILED. Rolling back to backup..."
  exit 1
fi

RESTORE_NEEDED=0
trap - EXIT

say "SUCCESS: ss-router-ssproxy-config completed."
echo "  - External IP (router may show ISP IP): curl -4 https://api.ipify.org"
echo "  - DNS via SS: dig @127.0.0.1 -p ${TUNNEL_PORT} CH TXT whoami.cloudflare +short"
[ -n "$BACKUP_DIR" ] && echo "  - Backup stored at: $BACKUP_DIR"
