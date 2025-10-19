#!/bin/sh
# === ss-router-provision.sh =================================================
# One-shot Shadowsocks client + DNS tunnel + UDP TPROXY + QUIC block
# for GL.iNet / OpenWrt routers.
#
# Run on the ROUTER as root:
#   Edit the variables below (SS_HOST, SS_PASS, etc) then:
#   sh /root/ss-router-provision.sh
#
# NOTE: This script is idempotent and safe to re-run, but review before running.

# ---- 0) SETTINGS (edit or export before running) ----------------------------
: "${SS_HOST:=YOUR_SS_SERVER_IP_OR_HOSTNAME}"     # <- REPLACE with your server host/IP
: "${SS_PORT:=8388}"                              # <- change if your server uses another port
: "${SS_PASS:=YOUR_SS_PASSWORD}"                  # <- REPLACE with your server password
: "${SS_METHOD:=chacha20-ietf-poly1305}"          # recommended cipher
: "${REDIR_PORT:=1081}"                           # local ss-redir port
: "${TUNNEL_PORT:=8054}"                          # local ss-tunnel DNS port
: "${UPSTREAM_DNS:=1.1.1.1:53}"                   # DNS that ss-tunnel will forward to
: "${WORKERS:=2}"                                 # number of ss-redir worker instances
: "${BLOCK_QUIC:=1}"                              # 1=add QUIC (UDP/443) DROP rule

set -eu

say()  { printf "\n[*] %s\n" "$*"; }
ok()   { printf "    ✓ %s\n" "$*"; }
warn() { printf "    ! %s\n" "$*"; }

# ---- 1) Pre-flight: try to ensure packages are present ----------------------
say "Attempting to install required packages (non-fatal if already present)..."
opkg update >/dev/null 2>&1 || true
opkg install -V0 shadowsocks-libev-ss-redir shadowsocks-libev-ss-tunnel shadowsocks-libev-config \
  ip-full iptables-mod-tproxy kmod-nf-tproxy kmod-nf-conntrack 2>/dev/null || true
ok "Package install attempted."

# ---- 2) Create procd service for Shadowsocks (ss-redir + ss-tunnel) ---------
say "Installing /etc/init.d/ssproxy (procd service)..."
cat >/etc/init.d/ssproxy <<'EOF'
#!/bin/sh /etc/rc.common
START=98
USE_PROCD=1

REDIR_BIN="/usr/bin/ss-redir"
TUNNEL_BIN="/usr/bin/ss-tunnel"

: "${SS_HOST:=YOUR_SS_SERVER_IP_OR_HOSTNAME}"
: "${SS_PORT:=8388}"
: "${SS_PASS:=YOUR_SS_PASSWORD}"
: "${SS_METHOD:=chacha20-ietf-poly1305}"
: "${REDIR_PORT:=1081}"
: "${TUNNEL_PORT:=8054}"
: "${UPSTREAM_DNS:=1.1.1.1:53}"
: "${WORKERS:=2}"

start_service() {
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

# ---- 3) DNS: route router DNS through ss-tunnel ----------------------------
say "Configuring dnsmasq to forward DNS to 127.0.0.1:${TUNNEL_PORT}..."
mkdir -p /etc/dnsmasq.d
cat >/etc/dnsmasq.d/shadowsocks.conf <<EOF
no-resolv
server=127.0.0.1#${TUNNEL_PORT}
EOF

uci -q set dhcp.@dnsmasq[0].noresolv='1'
uci -q set dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
# remove previous explicit server entries and add ours
uci -q del dhcp.@dnsmasq[0].server 2>/dev/null || true
uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#${TUNNEL_PORT}"
uci commit dhcp
/etc/init.d/dnsmasq restart
ok "dnsmasq configured to use ss-tunnel."

# ---- 4) Optional: block QUIC (UDP/443) to avoid browser bypass -------------
if [ "$BLOCK_QUIC" -eq 1 ]; then
  say "Adding UCI firewall rule to DROP LAN->WAN UDP/443 (QUIC) ..."
  uci -q delete firewall.ss_block_quic 2>/dev/null || true
  uci set firewall.ss_block_quic="rule"
  uci set firewall.ss_block_quic.name="Block-QUIC-UDP443"
  uci set firewall.ss_block_quic.src="lan"
  uci set firewall.ss_block_quic.dest="wan"
  uci set firewall.ss_block_quic.proto="udp"
  uci set firewall.ss_block_quic.dest_port="443"
  uci set firewall.ss_block_quic.target="DROP"
  uci commit firewall
  ok "QUIC block rule added."
fi

# ---- 5) disable flow offloading (avoid bypass) -----------------------------
say "Disabling flow_offloading (to avoid firewall bypass on some builds)..."
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# ---- 6) Persist TPROXY and NAT redirect in /etc/firewall.user ----------------
say "Writing persistent firewall.user with TPROXY + NAT redirect rules..."
cat >/etc/firewall.user <<EOF
# Shadowsocks persistent rules (written by ss-router-provision.sh)
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
ok "Firewall.user written and firewall restarted."

# ---- 7) Enable TCP Fast Open on router ------------------------------------
say "Enabling TCP Fast Open and persisting..."
sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null || true
if ! grep -q '^net.ipv4.tcp_fastopen' /etc/sysctl.conf 2>/dev/null; then
  echo 'net.ipv4.tcp_fastopen=3' >> /etc/sysctl.conf
fi
ok "TCP Fast Open set."

# ---- 8) Start the ssproxy service -----------------------------------------
say "Starting ssproxy (ss-redir workers + ss-tunnel)..."
/etc/init.d/ssproxy restart || true
sleep 1
ok "ssproxy restarted."

# ---- 9) Quick verifications ------------------------------------------------
say "Quick checks (output below):"
ss -lntup | grep -E ":${REDIR_PORT}|:${TUNNEL_PORT}" || true
if command -v dig >/dev/null 2>&1; then
  dig @127.0.0.1 -p "${TUNNEL_PORT}" CH TXT whoami.cloudflare +short || true
fi

say "Done. Verify from a client:"
echo "  - curl -4 https://api.ipify.org   (should show ${SS_HOST})"
echo "  - dig @127.0.0.1 -p ${TUNNEL_PORT} CH TXT whoami.cloudflare +short"
echo
